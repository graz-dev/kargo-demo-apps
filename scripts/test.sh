#!/usr/bin/env bash
# Builds every catalog version (or the ones named), runs each container and checks the contract:
# good versions pass, the broken one answers 200 but fails the verification greps as designed,
# config.js is rendered with the right headers, and the OCI labels are set.
#
#   scripts/test.sh [version ...]
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT_DIR/scripts/catalog.sh"
STAGE="contract-test"
LAMBDA="https://backend.example.invalid/"

"$CATALOG" validate || exit 1
image="$("$CATALOG" image)"

if (($# == 0)); then
  # shellcheck disable=SC2046 # versions are simple words
  set -- $("$CATALOG" versions)
fi

"$ROOT_DIR/scripts/build.sh" "$@" || exit 1

CID=""
cleanup() { [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1; }
trap cleanup EXIT

FAILED=0
label() { docker image inspect --format "{{index .Config.Labels \"org.opencontainers.image.$2\"}}" "$1"; }

for v in "$@"; do
  broken="$("$CATALOG" get "$v" broken)"
  kind=good
  [[ "$broken" == true ]] && kind=bad
  printf '\n== %s:%s (%s)\n' "$image" "$v" "$kind"

  CID="$(docker run -d --rm -p 127.0.0.1::80 -e "STAGE=$STAGE" -e "LAMBDA_URL=$LAMBDA" "$image:$v")" || { FAILED=1; continue; }
  port="$(docker port "$CID" 80/tcp | head -1 | sed 's/.*://')"
  ready=0
  for _ in $(seq 1 30); do
    if curl -fs -o /dev/null "http://127.0.0.1:$port/"; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" != 1 ]]; then
    echo "    FAIL  container did not become ready"
    docker logs "$CID" 2>&1 | tail -5
    FAILED=1
    cleanup
    CID=""
    continue
  fi

  EXPECT_STAGE="$STAGE" EXPECT_LAMBDA_URL="$LAMBDA" \
    EXPECT_THEME="$("$CATALOG" get "$v" theme)" EXPECT_MESSAGE="$("$CATALOG" get "$v" message)" \
    "$ROOT_DIR/tests/contract.sh" "http://127.0.0.1:$port" "$v" "$kind" || FAILED=1

  # OCI labels: source, version, revision, created, title, description
  for l in source version revision created title description; do
    val="$(label "$image:$v" "$l")"
    if [[ -n "$val" ]]; then
      printf '    ok    label org.opencontainers.image.%s\n' "$l"
    else
      printf '    FAIL  label org.opencontainers.image.%s is empty\n' "$l"
      FAILED=1
    fi
  done
  if [[ "$(label "$image:$v" revision)" =~ ^([0-9a-f]{40}|unknown)$ ]]; then
    echo "    ok    label revision is a commit id (or 'unknown' before the first commit)"
  else
    echo "    FAIL  label revision is neither a 40-character commit id nor 'unknown'"
    FAILED=1
  fi
  if [[ "$(label "$image:$v" version)" == "$v" ]]; then
    echo "    ok    label version equals the tag"
  else
    echo "    FAIL  label version differs from the tag"
    FAILED=1
  fi

  cleanup
  CID=""
done

printf '\n'
if ((FAILED)); then
  echo "TESTS FAILED"
  exit 1
fi
echo "ALL TESTS PASSED ($# version(s))"
