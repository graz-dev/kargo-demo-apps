#!/usr/bin/env bash
# Tests scripts/publish.sh and scripts/teardown.sh WITHOUT touching GHCR:
#   - a throwaway local registry (localhost:5055) stands in for ghcr.io
#   - a mock of the GitHub Packages API (tests/mock-github-api.py) stands in for api.github.com
# Takes a few minutes the first time (pulls the registry and BuildKit images).
#
#   tests/publish-teardown.sh
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:3.1.2}"
PORT=5055
NAME=imgtest-registry
TMP="$(mktemp -d)"
MOCK_PID=""
FAILED=0

cleanup() {
  rm -f "$ROOT_DIR/.publish-test-dirty"
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" 2>/dev/null
    wait "$MOCK_PID" 2>/dev/null
  fi
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() { printf '    ok    %s\n' "$1"; }
fail() {
  printf '    FAIL  %s\n' "$1"
  FAILED=1
}
t() { # t <description> <command...>
  local d="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}
not() { ! "$@"; }

export IMAGE_REGISTRY="localhost:$PORT" IMAGE_OWNER=testowner ALLOW_DIRTY=1
REPO="$IMAGE_REGISTRY/$IMAGE_OWNER/kargo-workshop-guestbook"
PUBLISH="$ROOT_DIR/scripts/publish.sh"
TEARDOWN="$ROOT_DIR/scripts/teardown.sh"

digest() { docker buildx imagetools inspect "$REPO:$1" 2>/dev/null | awk '/^Digest:/ {print $2; exit}'; }
exists() { docker buildx imagetools inspect "$REPO:$1" >/dev/null 2>&1; }

docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --rm --name "$NAME" -p "127.0.0.1:$PORT:5000" "$REGISTRY_IMAGE" >/dev/null || { echo "cannot start the test registry"; exit 1; }
sleep 2

echo "== publish: dry run"
out="$("$PUBLISH" 1.0.0 2>&1)"
# shellcheck disable=SC2329 # called through t
dry_ok() { grep -q 'Dry run' <<<"$out"; }
t "a run without --yes says it is a dry run" dry_ok
t "a dry run pushes nothing" not exists 1.0.0

echo "== publish: real push of 1.0.0"
"$PUBLISH" 1.0.0 --yes >"$TMP/p1.log" 2>&1
t "publish --yes succeeds" test $? -eq 0
t "the tag now exists" exists 1.0.0
raw="$(docker buildx imagetools inspect "$REPO:1.0.0" --raw 2>/dev/null | tr -d ' \n')"
t "the index holds exactly 2 manifests" test "$(grep -o '"digest":"sha256' <<<"$raw" | wc -l | tr -d ' ')" = 2
t "the index has linux/amd64" grep -q '"architecture":"amd64","os":"linux"' <<<"$raw"
t "the index has linux/arm64" grep -q '"architecture":"arm64","os":"linux"' <<<"$raw"
t "the script printed the digest" grep -q "$(digest 1.0.0)" "$TMP/p1.log"
D1="$(digest 1.0.0)"

echo "== publish: guards"
"$PUBLISH" 1.0.0 --yes >"$TMP/p2.log" 2>&1
t "re-publishing an existing tag is refused" test $? -ne 0
t "...with a clear message" grep -q 'Already published' "$TMP/p2.log"
t "...and the tag is untouched" test "$(digest 1.0.0)" = "$D1"
"$PUBLISH" all --yes >"$TMP/p3.log" 2>&1
t "'all' is refused when any tag exists" test $? -ne 0
t "...and nothing else was pushed" not exists 1.1.0
"$PUBLISH" 9.9.9 --yes >"$TMP/p4.log" 2>&1
t "a version missing from the catalog is refused" test $? -ne 0
# A file that is not committed makes the tree dirty (and a repo without commits is refused even earlier)
DIRTY="$ROOT_DIR/.publish-test-dirty"
touch "$DIRTY"
ALLOW_DIRTY=0 "$PUBLISH" 1.1.0 --yes >"$TMP/p5.log" 2>&1
RC=$?
rm -f "$DIRTY"
t "without ALLOW_DIRTY an uncommitted tree is refused" test $RC -ne 0
t "...with a clear message" grep -q -E 'no commit yet|uncommitted changes' "$TMP/p5.log"
t "...and nothing was pushed" not exists 1.1.0
# A copy of the docker config (contexts and plugins stay) with every credential removed
mkdir -p "$TMP/nologin"
cp -R "${DOCKER_CONFIG:-$HOME/.docker}/." "$TMP/nologin/"
python3 -I - "$TMP/nologin/config.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for k in ("auths", "credsStore", "credHelpers"):
    d.pop(k, None)
json.dump(d, open(p, "w"))
PY
IMAGE_REGISTRY=ghcr.io DOCKER_CONFIG="$TMP/nologin" "$PUBLISH" 1.1.0 --yes >"$TMP/p6.log" 2>&1
t "pushing to ghcr.io without a login is refused" test $? -ne 0
t "...with a clear message" grep -q 'Not logged in to ghcr.io' "$TMP/p6.log"

echo "== publish: more versions"
"$PUBLISH" 1.1.0 --yes >/dev/null 2>&1
t "1.1.0 published" exists 1.1.0
"$PUBLISH" 1.3.0 --yes >/dev/null 2>&1
t "1.3.0 (the broken one) published" exists 1.3.0

echo "== teardown: against the mock API"
SEED="$TMP/seed.json"
python3 -I - "$SEED" "$REPO" <<'PY'
import json, subprocess, sys
seed_path, repo = sys.argv[1], sys.argv[2]
versions, next_id = [], 1000
def run(*a):
    return subprocess.run(a, capture_output=True, text=True, check=True).stdout
for tag in ("1.0.0", "1.1.0", "1.3.0"):
    out = run("docker", "buildx", "imagetools", "inspect", f"{repo}:{tag}")
    index = next(l.split()[1] for l in out.splitlines() if l.startswith("Digest:"))
    raw = json.loads(run("docker", "buildx", "imagetools", "inspect", f"{repo}:{tag}", "--raw"))
    versions.append({"id": next_id, "name": index, "tags": [tag]}); next_id += 1
    for m in raw["manifests"]:
        versions.append({"id": next_id, "name": m["digest"], "tags": []}); next_id += 1
# 105 unrelated untagged versions: forces a second page of results
for n in range(105):
    versions.append({"id": next_id, "name": f"sha256:{n:064x}", "tags": []}); next_id += 1
json.dump(versions, open(seed_path, "w"))
print(len(versions), "versions seeded")
PY
MOCK_PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -I "$ROOT_DIR/tests/mock-github-api.py" "$SEED" secret-token "$MOCK_PORT" &
MOCK_PID=$!
sleep 1
export GITHUB_API_URL="http://127.0.0.1:$MOCK_PORT"
state() { curl -s "$GITHUB_API_URL/__state"; }
count() { python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"$(state)"; }
TOTAL="$(count)"

env -u GITHUB_TOKEN "$TEARDOWN" 1.0.0 >"$TMP/t0.log" 2>&1
t "without GITHUB_TOKEN teardown refuses" test $? -ne 0
# Without GITHUB_TOKEN the token saved by `docker login` is used: a docker config with a login for the test registry
mkdir -p "$TMP/withlogin"
cp -R "${DOCKER_CONFIG:-$HOME/.docker}/." "$TMP/withlogin/"
python3 -I - "$TMP/withlogin/config.json" <<'PY'
import base64, json, sys
p = sys.argv[1]
d = json.load(open(p))
for k in ("credsStore", "credHelpers"):
    d.pop(k, None)
d["auths"] = {"localhost:5055": {"auth": base64.b64encode(b"testowner:secret-token").decode()}}
json.dump(d, open(p, "w"))
PY
env -u GITHUB_TOKEN DOCKER_CONFIG="$TMP/withlogin" "$TEARDOWN" all >"$TMP/t00.log" 2>&1
t "without GITHUB_TOKEN the docker login token is used" test "$(grep -c '^  [0-9]' "$TMP/t00.log")" = "$TOTAL"
env -u GITHUB_TOKEN DOCKER_CONFIG="$TMP/nologin" "$TEARDOWN" all >"$TMP/t01.log" 2>&1
t "no GITHUB_TOKEN and no docker login: refused with a clear message" grep -q 'No token' "$TMP/t01.log"
GITHUB_TOKEN=wrong "$TEARDOWN" 1.0.0 --yes >"$TMP/t1.log" 2>&1
t "a wrong token is refused (HTTP 401)" test $? -ne 0
t "...nothing deleted" test "$(count)" = "$TOTAL"
GITHUB_TOKEN=secret-token "$TEARDOWN" 1.0.0 >"$TMP/t2.log" 2>&1
t "dry run lists the 3 versions of 1.0.0 (index + 2 platforms)" test "$(grep -c '^  [0-9]' "$TMP/t2.log")" = 3
t "dry run deletes nothing" test "$(count)" = "$TOTAL"
GITHUB_TOKEN=secret-token "$TEARDOWN" 1.0.0 --yes >"$TMP/t3.log" 2>&1
t "teardown 1.0.0 --yes succeeds" test $? -eq 0
t "exactly 3 versions were deleted" test "$(count)" = "$((TOTAL - 3))"
GITHUB_TOKEN=secret-token "$TEARDOWN" 9.9.9 --yes >/dev/null 2>&1
t "a version missing from the catalog is refused" test $? -ne 0
GITHUB_TOKEN=secret-token "$TEARDOWN" 1.1.0 --yes >/dev/null 2>&1
t "teardown 1.1.0 --yes succeeds" test $? -eq 0
t "1.3.0 is still there (3 versions + the 105 unrelated)" test "$(count)" = "$((3 + 105))"
GITHUB_TOKEN=secret-token "$TEARDOWN" all >"$TMP/t4.log" 2>&1
t "'all' dry run lists every version, over two pages" test "$(grep -c '^  [0-9]' "$TMP/t4.log")" = "$((3 + 105))"
GITHUB_TOKEN=secret-token "$TEARDOWN" all --yes >/dev/null 2>&1
t "teardown all --yes empties the package" test "$(count)" = 0

echo
if ((FAILED)); then
  echo "TESTS FAILED"
  exit 1
fi
echo "ALL PUBLISH/TEARDOWN TESTS PASSED"
