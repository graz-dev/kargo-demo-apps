#!/usr/bin/env bash
# Contract tests for one running container. These are the same checks the workshop's
# AnalysisTemplates run (smoke-test and e2e-test grep the home page), plus the runtime-config contract.
#
#   tests/contract.sh <base-url> <version> <good|bad>
#
# Environment (what the container under test was started with / is expected to show):
#   EXPECT_STAGE (default contract-test)   EXPECT_LAMBDA_URL (default https://backend.example.invalid/)
#   EXPECT_THEME   EXPECT_MESSAGE          (optional: checked on the page when set)
set -uo pipefail

BASE="${1:?usage: contract.sh <base-url> <version> <good|bad>}"
VERSION="${2:?version}"
KIND="${3:?good|bad}"
[[ "$KIND" == good || "$KIND" == bad ]] || { echo "kind must be good or bad" >&2; exit 2; }

STAGE="${EXPECT_STAGE:-contract-test}"
LAMBDA="${EXPECT_LAMBDA_URL:-https://backend.example.invalid/}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILED=0
t() { # t <description> <command...>
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '    ok    %s\n' "$desc"
  else
    printf '    FAIL  %s\n' "$desc"
    FAILED=1
  fi
}
# These helpers are only called through `t`, which shellcheck cannot see
# shellcheck disable=SC2329
not() { ! "$@"; }

# The two checks of the Lab 4 AnalysisTemplates, verbatim
# shellcheck disable=SC2329
smoke_test() { grep -q "Kargo Guestbook" "$TMP/index"; }
# shellcheck disable=SC2329
e2e_test() { smoke_test && grep -q 'id="entry-form"' "$TMP/index"; }

status="$(curl -s -o "$TMP/index" -D "$TMP/index.headers" -w '%{http_code}' "$BASE/")"
t "GET / answers HTTP 200" test "$status" = 200
t "page has no unrendered @@placeholders@@" not grep -q '@@' "$TMP/index"
t "page shows the version $VERSION" grep -qF "$VERSION" "$TMP/index"
t "page shows the stage label" grep -q 'id="stage"' "$TMP/index"
t "page revalidates (Cache-Control: no-cache)" grep -qi '^cache-control: *no-cache' "$TMP/index.headers"
if [[ -n "${EXPECT_THEME:-}" ]]; then
  t "page uses theme ${EXPECT_THEME}" grep -q "data-theme=\"${EXPECT_THEME}\"" "$TMP/index"
fi
if [[ -n "${EXPECT_MESSAGE:-}" ]]; then
  t "page shows the release message" grep -qF "${EXPECT_MESSAGE}" "$TMP/index"
fi

if [[ "$KIND" == good ]]; then
  t "smoke-test passes (home page says Kargo Guestbook)" smoke_test
  t "e2e-test passes (guestbook form present)" e2e_test
  t "no failure banner" not grep -q 'Something went wrong' "$TMP/index"
else
  t "smoke-test FAILS as designed (no Kargo Guestbook on a 200 page)" not smoke_test
  t "e2e-test FAILS as designed" not e2e_test
  t "breakage is visible on the page" grep -q 'Something went wrong' "$TMP/index"
fi

cstatus="$(curl -s -o "$TMP/config.js" -D "$TMP/config.headers" -w '%{http_code}' "$BASE/config.js")"
t "GET /config.js answers HTTP 200" test "$cstatus" = 200
t "config.js is never cached (Cache-Control: no-store)" grep -qi '^cache-control: *no-store' "$TMP/config.headers"
t "config.js carries STAGE" grep -qF "stage: \"$STAGE\"" "$TMP/config.js"
t "config.js carries LAMBDA_URL" grep -qF "lambdaUrl: \"$LAMBDA\"" "$TMP/config.js"

exit "$FAILED"
