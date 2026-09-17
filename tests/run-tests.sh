#!/bin/sh
# Deterministic local contract tests for the public `install` bootstrap text.
#
# The tests never touch the network and never run a real codesign: they place
# test doubles for curl, codesign, and uname first on PATH and drive the real
# install script against deterministic server scenarios. They prove the
# Darwin/arm64 gate, strict argument parsing, alpha.json minimum-field
# resolution, acquisition bounds and redirect handling, attempt limits, Apple
# verification order and pins, the exact authenticated invocation, and
# temp-directory cleanup.
#
# Run with: sh tests/run-tests.sh

set -u

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
install_source=$repo_root/install

work=$(mktemp -d "${TMPDIR:-/tmp}/flh-release-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

bin=$work/bin
serve=$work/serve
fake_state=$work/fake-state
log=$work/commands.log
sandbox=$work/sandbox
stdout=$work/stdout
stderr=$work/stderr
expected=$work/expected.log
actual=$work/actual.log
mkdir -p "$bin" "$serve" "$fake_state" "$sandbox"

test_count=0
failure_count=0

pass() {
  test_count=$((test_count + 1))
  printf 'ok %d - %s\n' "$test_count" "$1"
}

fail() {
  test_count=$((test_count + 1))
  failure_count=$((failure_count + 1))
  printf 'not ok %d - %s\n' "$test_count" "$1"
}

assert_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1 (expected [$2], got [$3])"
  fi
}

assert_contains() {
  if grep -Fq -- "$3" "$2"; then
    pass "$1"
  else
    fail "$1 (missing [$3] in $2)"
  fi
}

assert_file_empty() {
  if [ ! -s "$2" ]; then
    pass "$1"
  else
    fail "$1 (expected $2 to be empty)"
  fi
}

assert_clean_sandbox() {
  leftovers=$(find "$sandbox" -mindepth 1 -print 2>/dev/null | tr '\n' ' ')
  if [ -z "$leftovers" ]; then
    pass "$1"
  else
    fail "$1 (leftover entries in $sandbox: $leftovers)"
  fi
}

count_matching() {
  grep -c -- "$1" "$log" 2>/dev/null || true
}

normalize_log() {
  sed 's#[^ ][^ ]*/flh-bootstrap\.[A-Za-z0-9]*#<tmp>#g' "$log"
}

assert_log_matches() {
  normalize_log > "$actual"
  if diff -u "$expected" "$actual" > "$work/diff.txt" 2>&1; then
    pass "$1"
  else
    fail "$1"
    sed 's/^/    /' "$work/diff.txt"
  fi
}

cat > "$bin/uname" <<'FAKE_UNAME'
#!/bin/sh
case ${1:-} in
  -s) printf '%s\n' "${FAKE_UNAME_S:-Darwin}" ;;
  -m) printf '%s\n' "${FAKE_UNAME_M:-arm64}" ;;
  *) printf '%s\n' "Darwin" ;;
esac
FAKE_UNAME
chmod +x "$bin/uname"

cat > "$bin/curl" <<'FAKE_CURL'
#!/bin/sh
set -u
{
  printf 'curl'
  for argument in "$@"; do printf ' %s' "$argument"; done
  printf '\n'
} >> "$FAKE_LOG"

out=
url=
previous=
for argument in "$@"; do
  case $previous in
    --output) out=$argument ;;
  esac
  case $argument in
    http://*|https://*) url=$argument ;;
  esac
  previous=$argument
done

behavior=${FAKE_CURL_BEHAVIOR:-ok}
case $url in
  */alpha.json)
    if [ -n "${FAKE_CURL_BEHAVIOR_ALPHA:-}" ]; then behavior=$FAKE_CURL_BEHAVIOR_ALPHA; fi
    ;;
  */flh-darwin-arm64)
    if [ -n "${FAKE_CURL_BEHAVIOR_BINARY:-}" ]; then behavior=$FAKE_CURL_BEHAVIOR_BINARY; fi
    ;;
esac

count_file=$FAKE_STATE_DIR/$(basename "$url").count
count=$(cat "$count_file" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "$behavior" = "flaky" ]; then
  if [ "$count" -le "${FAKE_FLAKY_FAILS:-0}" ]; then
    behavior=timeout
  else
    behavior=ok
  fi
fi

case $behavior in
  ok)
    source_file=$FAKE_SERVE_DIR/$(basename "$url")
    if [ ! -f "$source_file" ]; then
      printf '404'
      exit 0
    fi
    cat "$source_file" > "$out"
    chmod 644 "$out"
    printf '200'
    exit 0
    ;;
  http-404)
    printf '404'
    exit 0
    ;;
  http-500)
    printf '500'
    exit 0
    ;;
  timeout)
    exit 28
    ;;
  redirect-loop)
    exit 47
    ;;
  non-https)
    exit 1
    ;;
  oversize-declared)
    exit 63
    ;;
  oversize-stream)
    bytes=${FAKE_OVERSIZE_BYTES:-0}
    dd if=/dev/zero of="$out" bs=65536 count=$((bytes / 65536)) 2>/dev/null
    stream_status=$?
    printf 'stream-status %s\n' "$stream_status" >> "$FAKE_LOG"
    printf 'stream-size %s\n' "$(wc -c < "$out" 2>/dev/null | tr -d '[:space:]')" >> "$FAKE_LOG"
    printf '200'
    exit "$stream_status"
    ;;
hang)
  # A curl launched as an asynchronous POSIX-shell job inherits ignored INT.
  # TERM remains the reliable cancellation signal.
  trap '' INT
  trap 'printf "curl-signal TERM\n" >> "$FAKE_LOG"; exit 143' TERM
  printf 'curl-ready\n' >> "$FAKE_LOG"
  while :; do sleep 1; done
  ;;
  *)
    exit 96
    ;;
esac
FAKE_CURL
chmod +x "$bin/curl"

cat > "$bin/codesign" <<'FAKE_CODESIGN'
#!/bin/sh
set -u
{
  printf 'codesign'
  for argument in "$@"; do printf ' %s' "$argument"; done
  printf '\n'
} >> "$FAKE_LOG"

display=0
notarization=0
requirement=0
verify=0
for argument in "$@"; do
  case $argument in
    --display) display=1 ;;
    --check-notarization) notarization=1 ;;
    -R=*) requirement=1 ;;
    --verify) verify=1 ;;
  esac
done

behavior=${FAKE_CODESIGN_BEHAVIOR:-ok}
case $behavior in
  strict-fail)
    if [ "$verify" -eq 1 ] && [ "$requirement" -eq 0 ] && [ "$notarization" -eq 0 ]; then
      exit 1
    fi
    ;;
  requirement-fail)
    if [ "$requirement" -eq 1 ] && [ "$notarization" -eq 0 ]; then
      exit 1
    fi
    ;;
  notarization-fail)
    if [ "$notarization" -eq 1 ]; then
      exit 1
    fi
    ;;
esac

if [ "$display" -eq 1 ]; then
  if [ "$behavior" = "display-empty" ]; then
    exit 0
  fi
  team=${FAKE_CODESIGN_TEAM:-ABCDE12345}
  identifier=${FAKE_CODESIGN_IDENTIFIER:-com.giantwall.flh.bootstrap}
  if [ "$behavior" = "bad-team" ]; then
    team=WRONGTEAM1
  fi
  if [ "$behavior" = "bad-identifier" ]; then
    identifier=com.example.other
  fi
  printf 'Executable=%s\nIdentifier=%s\nTeamIdentifier=%s\n' "test-binary" "$identifier" "$team"
fi
exit 0
FAKE_CODESIGN
chmod +x "$bin/codesign"

# provision replaces the intentionally empty reviewed Apple pins in a copy of
# the install text. The public script has no test seams; tests provision a
# generated copy exactly the way a reviewed provisioning change would edit the
# three constants in place.
provision() {
  awk -v team="$2" -v identifier="$3" -v requirement="$4" '
    function shell_escape(value) {
      gsub(/\\/, "\\\\", value)
      gsub(/"/, "\\\"", value)
      return value
    }
    /^FLH_APPLE_TEAM_ID=""/ {
      printf "FLH_APPLE_TEAM_ID=\"%s\"\n", shell_escape(team)
      next
    }
    /^FLH_APPLE_CODE_IDENTIFIER=""/ {
      printf "FLH_APPLE_CODE_IDENTIFIER=\"%s\"\n", shell_escape(identifier)
      next
    }
    /^FLH_APPLE_DESIGNATED_REQUIREMENT=""/ {
      printf "FLH_APPLE_DESIGNATED_REQUIREMENT=\"%s\"\n", shell_escape(requirement)
      next
    }
    { print }
  ' "$install_source" > "$1"
}

provisioned=$work/install-provisioned
provision "$provisioned" ABCDE12345 com.giantwall.flh.bootstrap 'identifier "com.giantwall.flh.bootstrap" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345"'

candidate_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

write_alpha() {
  printf '%s\n' "$1" > "$serve/alpha.json"
}

write_standalone() {
  cat > "$serve/flh-darwin-arm64" <<'STANDALONE'
#!/bin/sh
{
  printf 'run'
  for argument in "$@"; do printf ' %s' "$argument"; done
  printf '\n'
} >> "$FAKE_LOG"
if [ "${FAKE_RUN_HANG:-0}" = "1" ]; then
  trap 'printf "child-signal TERM\n" >> "$FAKE_LOG"; exit 143' TERM
  trap 'printf "child-signal INT\n" >> "$FAKE_LOG"; exit 130' INT
  trap 'printf "child-unsafe HUP\n" >> "$FAKE_LOG"; exit 129' HUP
  printf 'child-ready\n' >> "$FAKE_LOG"
  while :; do sleep 1; done
fi
exit "${FAKE_RUN_EXIT:-0}"
STANDALONE
  chmod +x "$serve/flh-darwin-arm64"
}

reset_scenario() {
  alpha_behavior=ok
  binary_behavior=ok
  codesign_behavior=ok
  run_exit=0
  run_hang=0
  flaky_fails=0
  codesign_team=ABCDE12345
  codesign_identifier=com.giantwall.flh.bootstrap
  oversize_bytes=0
  uname_s=Darwin
  uname_m=arm64
  rm -rf -- "$serve" "$fake_state" "$sandbox"
  mkdir -p "$serve" "$fake_state" "$sandbox"
  write_alpha "{
  \"version\": \"v0.1.0-alpha.3\",
  \"candidate_sha256\": \"${candidate_sha256}\"
}"
  write_standalone
}

start_install() {
  script=$1
  shift
  : > "$log"
  env \
    PATH="$bin:$PATH" \
    TMPDIR="$sandbox" \
    FAKE_LOG="$log" \
    FAKE_SERVE_DIR="$serve" \
    FAKE_STATE_DIR="$fake_state" \
    FAKE_CURL_BEHAVIOR_ALPHA="$alpha_behavior" \
    FAKE_CURL_BEHAVIOR_BINARY="$binary_behavior" \
    FAKE_CODESIGN_BEHAVIOR="$codesign_behavior" \
    FAKE_RUN_EXIT="$run_exit" \
    FAKE_RUN_HANG="$run_hang" \
    FAKE_FLAKY_FAILS="$flaky_fails" \
    FAKE_CODESIGN_TEAM="$codesign_team" \
    FAKE_CODESIGN_IDENTIFIER="$codesign_identifier" \
    FAKE_OVERSIZE_BYTES="$oversize_bytes" \
    FAKE_UNAME_S="$uname_s" \
    FAKE_UNAME_M="$uname_m" \
    /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; $SIG{HUP} = "DEFAULT"; exec @ARGV' \
      sh "$script" "$@" > "$stdout" 2> "$stderr" &
  background_pid=$!
}

run_install() {
  start_install "$@"
  if wait "$background_pid"; then
    run_status=0
  else
    run_status=$?
  fi
}

test_repository_surface() {
  if [ -f "$repo_root/README.md" ]; then pass "README.md exists"; else fail "README.md exists"; fi
  if [ -f "$install_source" ]; then pass "install exists"; else fail "install exists"; fi
  if [ -f "$repo_root/alpha.json" ]; then pass "alpha.json exists"; else fail "alpha.json exists"; fi
  if sh -n "$install_source" 2>/dev/null; then pass "install passes sh -n"; else fail "install passes sh -n"; fi
  assert_contains "alpha.json records the no-promoted-version state" "$repo_root/alpha.json" '"state": "no-promoted-version"'
  if grep -Fq '"version"' "$repo_root/alpha.json"; then
    fail "alpha.json carries no promoted version"
  else
    pass "alpha.json carries no promoted version"
  fi
  if grep -Fq '"candidate_sha256"' "$repo_root/alpha.json"; then
    fail "alpha.json invents no candidate"
  else
    pass "alpha.json invents no candidate"
  fi
  assert_contains "test provisioning replaces the Team ID pin" "$provisioned" 'FLH_APPLE_TEAM_ID="ABCDE12345"'
  if grep -Fq 'FLH_APPLE_DESIGNATED_REQUIREMENT=""' "$provisioned"; then
    fail "test provisioning replaces every reviewed pin"
  else
    pass "test provisioning replaces every reviewed pin"
  fi
  for forbidden in 'release-descriptor' 'release-manifest' 'launchctl' 'tar '; do
    if grep -Fq -- "$forbidden" "$install_source"; then
      fail "install does not reference [$forbidden]"
    else
      pass "install does not reference [$forbidden]"
    fi
  done
}

test_unprovisioned() {
  reset_scenario
  run_install "$install_source" --version v0.1.0-alpha.3
  assert_eq "unprovisioned explicit: exit 1" 1 "$run_status"
  assert_contains "unprovisioned explicit: names the pins" "$stderr" "not provisioned"
  assert_file_empty "unprovisioned explicit: no fetch" "$log"
  assert_clean_sandbox "unprovisioned explicit: no temp created"

  reset_scenario
  run_install "$install_source"
  assert_eq "unprovisioned no-version: exit 1" 1 "$run_status"
  assert_contains "unprovisioned no-version: names the pins" "$stderr" "not provisioned"
  assert_file_empty "unprovisioned no-version: no fetch" "$log"
}

test_pin_validation() {
  reset_scenario
  bad_team=$work/install-bad-team
  provision "$bad_team" abcdefghij com.giantwall.flh.bootstrap 'identifier "com.giantwall.flh.bootstrap" and anchor apple generic and certificate leaf[subject.OU] = "abcdefghij"'
  run_install "$bad_team" --version v0.1.0-alpha.3
  assert_eq "lowercase team pin: exit 1" 1 "$run_status"
  assert_contains "lowercase team pin: diagnostic" "$stderr" "Team ID"
  assert_file_empty "lowercase team pin: no fetch" "$log"

  reset_scenario
  weak_requirement=$work/install-weak-requirement
  provision "$weak_requirement" ABCDE12345 com.giantwall.flh.bootstrap 'identifier "com.giantwall.flh.bootstrap"'
  run_install "$weak_requirement" --version v0.1.0-alpha.3
  assert_eq "noncanonical requirement pin: exit 1" 1 "$run_status"
  assert_contains "noncanonical requirement pin: diagnostic" "$stderr" "designated requirement"
  assert_file_empty "noncanonical requirement pin: no fetch" "$log"
}

test_usage_errors() {
  reset_scenario
  run_install "$provisioned" --version v0.1.0-alpha.3 --version v0.1.0-alpha.3
  assert_eq "duplicate --version: exit 2" 2 "$run_status"
  assert_contains "duplicate --version: diagnostic" "$stderr" "only once"

  run_install "$provisioned" --version
  assert_eq "missing --version value: exit 2" 2 "$run_status"

  run_install "$provisioned" --version ""
  assert_eq "empty --version value: exit 2" 2 "$run_status"

  run_install "$provisioned" --version v0.1.0-alpha.03
  assert_eq "leading zero version: exit 2" 2 "$run_status"

  run_install "$provisioned" --version v0.1.0
  assert_eq "non-production version: exit 2" 2 "$run_status"

  run_install "$provisioned" --version dev.0123456789abcdef0123456789abcdef01234567
  assert_eq "dev build version: exit 2" 2 "$run_status"

  run_install "$provisioned" --bogus
  assert_eq "unknown argument: exit 2" 2 "$run_status"

  run_install "$provisioned" v0.1.0-alpha.3
  assert_eq "stray positional: exit 2" 2 "$run_status"

  assert_file_empty "usage errors never fetch" "$log"
  assert_clean_sandbox "usage errors create no temp"
}

test_platform_gate() {
  reset_scenario
  uname_s=Linux
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "linux: exit 1" 1 "$run_status"
  assert_contains "linux: diagnostic" "$stderr" "unsupported platform"
  assert_file_empty "linux: no fetch" "$log"

  reset_scenario
  uname_m=x86_64
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "x86_64: exit 1" 1 "$run_status"
  assert_contains "x86_64: diagnostic" "$stderr" "unsupported architecture"
  assert_file_empty "x86_64: no fetch" "$log"
}

test_explicit_success() {
  reset_scenario
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "explicit: exit 0" 0 "$run_status"
  assert_eq "explicit: no alpha.json fetch" 0 "$(count_matching '/alpha.json')"
  assert_eq "explicit: one standalone fetch" 1 "$(count_matching 'download/v0.1.0-alpha.3/flh-darwin-arm64')"
  assert_eq "explicit: one authenticated invocation" 1 "$(count_matching '^run ')"
  assert_clean_sandbox "explicit: temp cleaned"
  cat > "$expected" <<'EXPECTED'
curl --disable --proto =https --proto-redir =https --max-redirs 5 --location --connect-timeout 30 --speed-limit 1 --speed-time 30 --max-time 300 --max-filesize 134217728 --silent --show-error --output <tmp>/flh-darwin-arm64 --write-out %{http_code} https://github.com/GiantWallAB/flh-releases/releases/download/v0.1.0-alpha.3/flh-darwin-arm64
codesign --verify --strict --verbose=4 <tmp>/flh-darwin-arm64
codesign --display --verbose=4 <tmp>/flh-darwin-arm64
codesign --verify -R=identifier "com.giantwall.flh.bootstrap" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" <tmp>/flh-darwin-arm64
codesign --verify --strict --verbose=4 --check-notarization -R=notarized <tmp>/flh-darwin-arm64
run --bootstrap-install --version v0.1.0-alpha.3 --arch arm64
EXPECTED
  assert_log_matches "explicit: exact bounded command sequence"
}

test_no_version_success() {
  reset_scenario
  run_install "$provisioned"
  assert_eq "no-version: exit 0" 0 "$run_status"
  assert_eq "no-version: one alpha.json fetch" 1 "$(count_matching '/alpha.json')"
  assert_eq "no-version: one standalone fetch" 1 "$(count_matching 'download/v0.1.0-alpha.3/flh-darwin-arm64')"
  assert_contains "no-version: exact resolved invocation" "$log" "run --bootstrap-install --version v0.1.0-alpha.3 --arch arm64"
  assert_clean_sandbox "no-version: temp cleaned"
  cat > "$expected" <<'EXPECTED'
curl --disable --proto =https --proto-redir =https --max-redirs 5 --location --connect-timeout 30 --speed-limit 1 --speed-time 30 --max-time 300 --max-filesize 65536 --silent --show-error --output <tmp>/alpha.json --write-out %{http_code} https://raw.githubusercontent.com/GiantWallAB/flh-releases/main/alpha.json
curl --disable --proto =https --proto-redir =https --max-redirs 5 --location --connect-timeout 30 --speed-limit 1 --speed-time 30 --max-time 300 --max-filesize 134217728 --silent --show-error --output <tmp>/flh-darwin-arm64 --write-out %{http_code} https://github.com/GiantWallAB/flh-releases/releases/download/v0.1.0-alpha.3/flh-darwin-arm64
codesign --verify --strict --verbose=4 <tmp>/flh-darwin-arm64
codesign --display --verbose=4 <tmp>/flh-darwin-arm64
codesign --verify -R=identifier "com.giantwall.flh.bootstrap" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" <tmp>/flh-darwin-arm64
codesign --verify --strict --verbose=4 --check-notarization -R=notarized <tmp>/flh-darwin-arm64
run --bootstrap-install --version v0.1.0-alpha.3 --arch arm64
EXPECTED
  assert_log_matches "no-version: exact bounded command sequence"
}

test_alpha_parsing() {
  reset_scenario
  write_alpha '{
  "version": "v0.2.0-alpha.7",
  "candidate_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "promotion_id": "promo-123",
  "note": {"k": [1, 2]}
}'
  run_install "$provisioned"
  assert_eq "alpha additive fields: exit 0" 0 "$run_status"
  assert_contains "alpha additive fields: resolved version" "$log" "download/v0.2.0-alpha.7/flh-darwin-arm64"

  # An additive nested object reusing the reserved names must be ignored; a
  # line-based reader would have counted the nested version key as a second
  # identity and rejected a valid document.
  reset_scenario
  write_alpha '{
  "version": "v0.2.0-alpha.7",
  "candidate_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "meta": {"version": "v9", "candidate_sha256": "not-a-digest"}
}'
  run_install "$provisioned"
  assert_eq "alpha nested additive identities: exit 0" 0 "$run_status"
  assert_contains "alpha nested additive identities: resolved version" "$log" "download/v0.2.0-alpha.7/flh-darwin-arm64"

  # A nested-only identity is not a top-level identity.
  reset_scenario
  write_alpha '{
  "meta": {
    "version": "v0.2.0-alpha.7",
    "candidate_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
}'
  run_install "$provisioned"
  assert_eq "alpha nested-only identity: exit 1" 1 "$run_status"
  assert_contains "alpha nested-only identity: diagnostic" "$stderr" "no promoted version"
  assert_eq "alpha nested-only identity: no standalone fetch" 0 "$(count_matching 'download/')"

  reset_scenario
  write_alpha '{
  "version": "v0.2.0-alpha.7",
  "candidate_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "note": "version"
}'
  run_install "$provisioned"
  assert_eq "alpha literal additive value: exit 0" 0 "$run_status"
  assert_contains "alpha literal additive value: resolved version" "$log" "download/v0.2.0-alpha.7/flh-darwin-arm64"

  # JSON string escapes are decoded structurally before the grammar check.
  reset_scenario
  write_alpha '{"version":"v0.1.0-\u0061lpha.3","candidate_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  run_install "$provisioned"
  assert_eq "alpha escaped canonical version: exit 0" 0 "$run_status"
  assert_contains "alpha escaped canonical version: resolved version" "$log" "download/v0.1.0-alpha.3/flh-darwin-arm64"

  reset_scenario
  write_alpha '{"state":"no-promoted-version"}'
  run_install "$provisioned"
  assert_eq "alpha unpromoted: exit 1" 1 "$run_status"
  assert_contains "alpha unpromoted: diagnostic" "$stderr" "no promoted version"
  assert_eq "alpha unpromoted: no standalone fetch" 0 "$(count_matching 'download/')"
  assert_clean_sandbox "alpha unpromoted: temp cleaned"

  reset_scenario
  write_alpha '{"version":"v0.1.0-alpha.3"}'
  run_install "$provisioned"
  assert_eq "alpha missing candidate: exit 1" 1 "$run_status"
  assert_contains "alpha missing candidate: diagnostic" "$stderr" "candidate_sha256"
  assert_eq "alpha missing candidate: no standalone fetch" 0 "$(count_matching 'download/')"

  reset_scenario
  write_alpha '{"version":"v0.1.0-alpha.3",'
  run_install "$provisioned"
  assert_eq "alpha malformed JSON: exit 1" 1 "$run_status"
  assert_contains "alpha malformed JSON: diagnostic" "$stderr" "not valid JSON"
  assert_eq "alpha malformed JSON: no standalone fetch" 0 "$(count_matching 'download/')"

  reset_scenario
  write_alpha '{"version":"v0.1.0-alpha.3","candidate_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"} trailing'
  run_install "$provisioned"
  assert_eq "alpha trailing data: exit 1" 1 "$run_status"
  assert_contains "alpha trailing data: diagnostic" "$stderr" "not valid JSON"

  reset_scenario
  write_alpha '{"version":"v0.1.0-alpha.03","candidate_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  run_install "$provisioned"
  assert_eq "alpha malformed version: exit 1" 1 "$run_status"
  assert_contains "alpha malformed version: diagnostic" "$stderr" "not a production version"

  reset_scenario
  write_alpha '{"version":"v0.1.0-alpha.3\n","candidate_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  run_install "$provisioned"
  assert_eq "alpha newline escape in version: exit 1" 1 "$run_status"
  assert_contains "alpha newline escape in version: diagnostic" "$stderr" "not a production version"

  reset_scenario
  write_alpha '{"version":123,"candidate_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  run_install "$provisioned"
  assert_eq "alpha non-string version: exit 1" 1 "$run_status"
  assert_contains "alpha non-string version: diagnostic" "$stderr" "not a JSON string"

  reset_scenario
  write_alpha '{"version":"v0.1.0-alpha.3","candidate_sha256":"aaaa"}'
  run_install "$provisioned"
  assert_eq "alpha noncanonical candidate: exit 1" 1 "$run_status"
  assert_contains "alpha noncanonical candidate: diagnostic" "$stderr" "candidate_sha256"

  reset_scenario
  write_alpha '{"version":"v0.1.0-alpha.3","candidate_sha256":123}'
  run_install "$provisioned"
  assert_eq "alpha non-string candidate: exit 1" 1 "$run_status"
  assert_contains "alpha non-string candidate: diagnostic" "$stderr" "candidate_sha256 is not a JSON string"

  reset_scenario
  write_alpha '{"version":"v0.1.0-alpha.3","version":"v0.1.0-alpha.3","candidate_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  run_install "$provisioned"
  assert_eq "alpha duplicate top-level version: exit 1" 1 "$run_status"
  assert_contains "alpha duplicate top-level version: diagnostic" "$stderr" "duplicate object keys"

  reset_scenario
  write_alpha '{"version":"v0.1.0-alpha.3","candidate_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","meta":{"k":1,"k":2}}'
  run_install "$provisioned"
  assert_eq "alpha duplicate nested key: exit 1" 1 "$run_status"
  assert_contains "alpha duplicate nested key: diagnostic" "$stderr" "duplicate object keys"

  # Duplicate detection is on decoded keys: an escaped spelling of a key that
  # another literal key already used is still a duplicate.
  reset_scenario
  write_alpha '{"version":"v0.1.0-alpha.3","candidate_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","m\u0065ta":1,"meta":2}'
  run_install "$provisioned"
  assert_eq "alpha duplicate decoded keys: exit 1" 1 "$run_status"
  assert_contains "alpha duplicate decoded keys: diagnostic" "$stderr" "duplicate object keys"

  reset_scenario
  write_alpha '[]'
  run_install "$provisioned"
  assert_eq "alpha non-object: exit 1" 1 "$run_status"
  assert_contains "alpha non-object: diagnostic" "$stderr" "not a JSON object"
}

test_fetch_bounds() {
  reset_scenario
  alpha_behavior=oversize-declared
  run_install "$provisioned"
  assert_eq "alpha declared oversize: exit 1" 1 "$run_status"
  assert_contains "alpha declared oversize: diagnostic" "$stderr" "limit"
  assert_eq "alpha declared oversize: no retry" 1 "$(count_matching '/alpha.json')"
  assert_eq "alpha declared oversize: no standalone fetch" 0 "$(count_matching 'flh-darwin-arm64')"

  reset_scenario
  alpha_behavior=oversize-stream
  oversize_bytes=1048576
  run_install "$provisioned"
  assert_eq "alpha streamed oversize: exit 1" 1 "$run_status"
  assert_contains "alpha streamed oversize: diagnostic" "$stderr" "limit"
  assert_eq "alpha streamed oversize: no retry" 1 "$(count_matching '/alpha.json')"
  assert_eq "alpha streamed oversize: no standalone fetch" 0 "$(count_matching 'download/')"
  assert_contains "alpha streamed oversize: writer stopped by the OS limit" "$log" "stream-status 153"
  assert_eq "alpha streamed oversize: destination never exceeded the cap" 65536 "$(sed -n 's/^stream-size //p' "$log" | tail -1)"

  reset_scenario
  binary_behavior=oversize-declared
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "standalone declared oversize: exit 1" 1 "$run_status"
  assert_eq "standalone declared oversize: no retry" 1 "$(count_matching 'download/v0.1.0-alpha.3/flh-darwin-arm64')"
  assert_eq "standalone declared oversize: never verified" 0 "$(count_matching '^codesign ')"
  assert_eq "standalone declared oversize: never run" 0 "$(count_matching '^run ')"

  reset_scenario
  binary_behavior=oversize-stream
  oversize_bytes=268435456
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "standalone streamed oversize: exit 1" 1 "$run_status"
  assert_contains "standalone streamed oversize: diagnostic" "$stderr" "limit"
  assert_eq "standalone streamed oversize: no retry" 1 "$(count_matching 'download/v0.1.0-alpha.3/flh-darwin-arm64')"
  assert_eq "standalone streamed oversize: never verified" 0 "$(count_matching '^codesign ')"
  assert_eq "standalone streamed oversize: never run" 0 "$(count_matching '^run ')"
  assert_contains "standalone streamed oversize: writer stopped by the OS limit" "$log" "stream-status 153"
  assert_eq "standalone streamed oversize: destination never exceeded the cap" 134217728 "$(sed -n 's/^stream-size //p' "$log" | tail -1)"
  assert_clean_sandbox "standalone streamed oversize: temp cleaned"
}

test_redirect_policy() {
  reset_scenario
  alpha_behavior=redirect-loop
  run_install "$provisioned"
  assert_eq "redirect limit: exit 1" 1 "$run_status"
  assert_contains "redirect limit: diagnostic" "$stderr" "redirect limit"
  assert_eq "redirect limit: no retry" 1 "$(count_matching '/alpha.json')"

  reset_scenario
  alpha_behavior=non-https
  run_install "$provisioned"
  assert_eq "non-HTTPS redirect: exit 1" 1 "$run_status"
  assert_contains "non-HTTPS redirect: diagnostic" "$stderr" "non-HTTPS"
  assert_eq "non-HTTPS redirect: no retry" 1 "$(count_matching '/alpha.json')"

  reset_scenario
  binary_behavior=redirect-loop
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "binary redirect limit: exit 1" 1 "$run_status"
  assert_eq "binary redirect limit: no verification" 0 "$(count_matching '^codesign ')"
  assert_eq "binary redirect limit: never run" 0 "$(count_matching '^run ')"
}

test_attempt_budget() {
  reset_scenario
  alpha_behavior=timeout
  run_install "$provisioned"
  assert_eq "timeout: exit 1" 1 "$run_status"
  assert_eq "timeout: three attempts" 3 "$(count_matching '/alpha.json')"
  assert_contains "timeout: attempt diagnostic" "$stderr" "after 3 attempts"

  reset_scenario
  alpha_behavior=http-500
  run_install "$provisioned"
  assert_eq "HTTP 500: exit 1" 1 "$run_status"
  assert_eq "HTTP 500: three attempts" 3 "$(count_matching '/alpha.json')"

  reset_scenario
  alpha_behavior=http-404
  run_install "$provisioned"
  assert_eq "HTTP 404: exit 1" 1 "$run_status"
  assert_eq "HTTP 404: no retry" 1 "$(count_matching '/alpha.json')"

  reset_scenario
  alpha_behavior=flaky
  flaky_fails=2
  run_install "$provisioned"
  assert_eq "flaky recovery: exit 0" 0 "$run_status"
  assert_eq "flaky recovery: three attempts" 3 "$(count_matching '/alpha.json')"
  assert_eq "flaky recovery: one invocation" 1 "$(count_matching '^run ')"
}

test_apple_verification_failures() {
  reset_scenario
  codesign_behavior=strict-fail
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "strict failure: exit 1" 1 "$run_status"
  assert_eq "strict failure: one codesign call" 1 "$(count_matching '^codesign ')"
  assert_eq "strict failure: verification not retried" 1 "$(count_matching 'download/v0.1.0-alpha.3/flh-darwin-arm64')"
  assert_eq "strict failure: never run" 0 "$(count_matching '^run ')"
  assert_clean_sandbox "strict failure: temp cleaned"

  reset_scenario
  codesign_behavior=bad-team
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "bad team: exit 1" 1 "$run_status"
  assert_contains "bad team: diagnostic" "$stderr" "Team ID"
  assert_eq "bad team: stops before requirement" 2 "$(count_matching '^codesign ')"
  assert_eq "bad team: never run" 0 "$(count_matching '^run ')"

  reset_scenario
  codesign_behavior=bad-identifier
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "bad identifier: exit 1" 1 "$run_status"
  assert_contains "bad identifier: diagnostic" "$stderr" "code identifier"
  assert_eq "bad identifier: stops before requirement" 2 "$(count_matching '^codesign ')"

  reset_scenario
  codesign_behavior=display-empty
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "missing signature fields: exit 1" 1 "$run_status"
  assert_eq "missing signature fields: stops before requirement" 2 "$(count_matching '^codesign ')"

  reset_scenario
  codesign_behavior=requirement-fail
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "requirement failure: exit 1" 1 "$run_status"
  assert_contains "requirement failure: diagnostic" "$stderr" "designated requirement"
  assert_eq "requirement failure: three codesign calls" 3 "$(count_matching '^codesign ')"
  assert_eq "requirement failure: never run" 0 "$(count_matching '^run ')"

  reset_scenario
  codesign_behavior=notarization-fail
  run_install "$provisioned" --version v0.1.0-alpha.3
  assert_eq "notarization failure: exit 1" 1 "$run_status"
  assert_contains "notarization failure: diagnostic" "$stderr" "notarization ticket"
  assert_contains "notarization failure: explicit requirement check" "$log" "--check-notarization -R=notarized"
  assert_eq "notarization failure: four codesign calls" 4 "$(count_matching '^codesign ')"
  assert_eq "notarization failure: never run" 0 "$(count_matching '^run ')"
  assert_clean_sandbox "notarization failure: temp cleaned"
}

test_invocation_and_exit() {
  reset_scenario
  run_exit=7
  run_install "$provisioned"
  assert_eq "child exit status propagated" 7 "$run_status"
  assert_eq "child invoked once" 1 "$(count_matching '^run ')"
  assert_clean_sandbox "child exit: temp cleaned"
}

test_version_injection() {
  reset_scenario
  newline_junk='v0.1.0-alpha.3
junk'
  run_install "$provisioned" --version "$newline_junk"
  assert_eq "version with newline junk: exit 2" 2 "$run_status"
  assert_file_empty "version with newline junk: no fetch" "$log"

  reset_scenario
  preceding_line='junk
v0.1.0-alpha.3'
  run_install "$provisioned" --version "$preceding_line"
  assert_eq "version after a preceding line: exit 2" 2 "$run_status"
  assert_file_empty "version after a preceding line: no fetch" "$log"

  reset_scenario
  trailing_newline='v0.1.0-alpha.3
'
  run_install "$provisioned" --version "$trailing_newline"
  assert_eq "version with a trailing newline: exit 2" 2 "$run_status"
  assert_file_empty "version with a trailing newline: no fetch" "$log"

  reset_scenario
  trailing_cr=$(printf 'v0.1.0-alpha.3\r')
  run_install "$provisioned" --version "$trailing_cr"
  assert_eq "version with a trailing carriage return: exit 2" 2 "$run_status"
  assert_file_empty "version with a trailing carriage return: no fetch" "$log"

  assert_clean_sandbox "version injection creates no temp"
}

test_signal_cleanup() {
  reset_scenario
  alpha_behavior=hang
  start_install "$provisioned"
  waited=0
  while ! grep -Fq 'curl-ready' "$log" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if ! grep -Fq 'curl-ready' "$log" 2>/dev/null; then
    fail "INT fetch cancellation: script reached the hanging fetch"
    kill "$background_pid" 2>/dev/null || true
    wait "$background_pid" 2>/dev/null || true
    return
  fi
  kill -INT "$background_pid" 2>/dev/null || true
  wait "$background_pid" 2>/dev/null
  signal_status=$?
  assert_eq "INT fetch cancellation: exit status" 130 "$signal_status"
  assert_contains "INT fetch cancellation: curl received TERM" "$log" "curl-signal TERM"
  assert_clean_sandbox "INT fetch cancellation: temp cleaned"
}

test_signal_during_handoff() {
  reset_scenario
  run_hang=1
  start_install "$provisioned" --version v0.1.0-alpha.3
  waited=0
  while ! grep -Fq 'child-ready' "$log" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if ! grep -Fq 'child-ready' "$log" 2>/dev/null; then
    fail "handoff signal: authenticated child reached the handoff"
    kill "$background_pid" 2>/dev/null || true
    wait "$background_pid" 2>/dev/null || true
    return
  fi
  kill -HUP "$background_pid" 2>/dev/null || true
  wait "$background_pid" 2>/dev/null
  signal_status=$?
  assert_eq "HUP handoff cancellation: exit status" 129 "$signal_status"
  assert_contains "HUP handoff cancellation: child received TERM" "$log" "child-signal TERM"
  if grep -Fq 'child-unsafe HUP' "$log"; then
    fail "HUP handoff cancellation: HUP was forwarded unsafely"
  else
    pass "HUP handoff cancellation: HUP was not forwarded"
  fi
  assert_eq "handoff signal: one authenticated invocation" 1 "$(count_matching '^run ')"
  assert_eq "HUP handoff cancellation: child did not outlive the script" 1 "$(count_matching 'child-signal')"
  assert_clean_sandbox "HUP handoff cancellation: temp cleaned"
}

test_repository_surface
test_unprovisioned
test_pin_validation
test_usage_errors
test_version_injection
test_platform_gate
test_explicit_success
test_no_version_success
test_alpha_parsing
test_fetch_bounds
test_redirect_policy
test_attempt_budget
test_apple_verification_failures
test_invocation_and_exit
test_signal_cleanup
test_signal_during_handoff

printf '\n%s passed, %s failed\n' "$((test_count - failure_count))" "$failure_count"
if [ "$failure_count" -eq 0 ]; then
  exit 0
fi
exit 1
