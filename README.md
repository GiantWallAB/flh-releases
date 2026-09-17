# flh-releases

Public release repository for the FLH macOS alpha. It contains the canonical
public bootstrap text, the promoted-alpha pointer, and — in GitHub Releases —
versioned, immutable installable client artifacts.

```text
README.md          this document
install            canonical public bootstrap text (POSIX sh)
alpha.json         currently promoted alpha version (none yet)
tests/run-tests.sh deterministic local contract tests for the bootstrap text
```

This repository contains no FLH release keys and no Apple signing or
notarization credentials. Release key material ships only inside the signed
`flh` executable; Apple credentials live only in the release pipeline's secret
store.

## Install

Canonical bootstrap (resolves the promoted alpha from `alpha.json`):

```sh
curl -fsSL https://raw.githubusercontent.com/GiantWallAB/flh-releases/main/install | sh
```

Exact-version bootstrap (alpha QA and unpromoted candidates; never consults
`alpha.json`):

```sh
curl -fsSL https://raw.githubusercontent.com/GiantWallAB/flh-releases/main/install \
  | sh -s -- --version v0.1.0-alpha.3
```

`flh-darwin-arm64` must be a published, immutable GitHub Release asset under
that exact tag. The bootstrap installs on `darwin/arm64` only.

## Current state: fail-closed and unprovisioned

Two reviewed production inputs are intentionally not provisioned yet; until a
reviewed change provides them, every installation path fails closed:

- `alpha.json` carries no promoted version (`"state":
  "no-promoted-version"`). The no-version bootstrap and `flh upgrade` fail
  closed with a bounded error instead of guessing; the exact-version form
  remains the way to install a published candidate.
- The bootstrap's reviewed Apple pins — `FLH_APPLE_TEAM_ID`,
  `FLH_APPLE_CODE_IDENTIFIER`, and `FLH_APPLE_DESIGNATED_REQUIREMENT` in
  `install` — are empty. The bootstrap fails closed before any network fetch
  and before any downloaded executable can run. The `flh` executable's
  embedded release public key set is likewise empty until provisioned, so
  descriptor/archive acquisition also fails closed.

No identities are invented in this repository. Provisioning is a reviewed
change that fills those exact constants; the surrounding verification code is
already in place.

## What the bootstrap does

`install` owns only the public bootstrap responsibilities:

1. require `Darwin` / `arm64`;
2. parse strictly: no `--version`, or `--version <canonical production
   version>`; anything else is a usage error;
3. with no `--version`, read `alpha.json` and require exactly one canonical
   `version` (`v<major>.<minor>.<patch>-alpha.<ordinal>`) and exactly one
   lowercase 64-hex `candidate_sha256`; additive fields are ignored, and an
   absent version fails closed;
4. create one private mode-0700 bootstrap temp directory;
5. download `flh-darwin-arm64` over HTTPS with at most 5 redirects, a
   30-second connect/response-header deadline, a 5-minute per-attempt
   transfer deadline, at most 3 transport attempts (a verification failure is
   never retried), and a 128 MiB cap enforced on both the declared length and
   the bytes actually written;
6. authenticate the downloaded executable with the full Apple chain before
   anything downloaded may run: `codesign --verify --strict --verbose=4`, the
   exact pinned `TeamIdentifier`, the exact pinned code identifier, the
   pinned designated requirement, and the explicit online notarization-ticket
   check `codesign --verify --strict --verbose=4 --check-notarization
   -R=notarized`; `spctl` is deliberately absent because it rejects a validly
   signed bare Mach-O as "not an app";
7. invoke only that authenticated executable as
   `flh-darwin-arm64 --bootstrap-install --version <resolved> --arch arm64`;
8. remove the bootstrap temp directory on every exit path.

It does not parse release descriptors or installed manifests, extract
archives, mutate LaunchAgents, or duplicate installer logic. The `flh`
bootstrap entrypoint and the installed `flh upgrade` share the descriptor,
archive, installed-manifest, and installer transaction implementation; the
shell installer inside the authenticated release remains the sole mutation,
locking, revalidation, and rollback owner.

## Trust boundary

The `install` text is trusted by provenance — GitHub repository write control
plus HTTPS — not by an FLH release signature. The canonical `curl ... | sh`
invocation retrieves this text with the invoking shell's own curl before any
FLH code runs, so neither that outer transfer nor its bytes are bounded by
FLH; qualification records the exact consumed script bytes and promotion
rechecks them. Every fetch the script itself performs is bounded as described
above, and every downloaded release payload is authenticated before it
executes or is installed.

## Promotion

Promotion is serialized and compare-and-swap: `alpha.json` is updated only if
its live bytes still equal the predecessor state recorded in qualification
evidence. On the first promotion the recorded state is this repository's
no-promoted-version document, and the promoted document adds the candidate
`version` and `candidate_sha256` (plus promotion metadata such as
`promotion_id`), which older readers ignore.

## Tests

The bootstrap contract has a deterministic local test harness that runs
without network access and without real `codesign` execution:

```sh
sh tests/run-tests.sh
```

It stubs `curl`, `codesign`, and `uname` on `PATH` to prove Darwin/arm64
gating, strict argument parsing, `alpha.json` minimum-field resolution,
acquisition bounds and redirect handling, attempt limits, Apple verification
order and pins, the exact standalone invocation, and temp-directory cleanup.
