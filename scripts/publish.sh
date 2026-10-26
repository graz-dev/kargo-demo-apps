#!/usr/bin/env bash
# Pushes multi-arch images (linux/amd64 + linux/arm64) of catalog versions to the registry, from this machine.
# Guarded: without --yes (or CONFIRM=yes) it only checks everything and builds without pushing.
#
#   scripts/publish.sh <version|all> [--yes]
#
# Guards, in order: the catalog is valid · the working tree is clean and HEAD exists (the revision label must
# point at a real commit; ALLOW_DIRTY=1 overrides, for tests) · you are logged in to ghcr.io · none of the tags
# exists yet (existing tags are never overwritten, and "all" refuses if any exists) · the image builds for both
# platforms. After the push each manifest is checked for both platforms and its digest is printed.
#
# Credentials: your own `docker login ghcr.io` (a token with write:packages). Nothing is read from the repo.
# Overridable for tests: IMAGE_REGISTRY, IMAGE_OWNER, IMAGE_NAME.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLATFORMS="linux/amd64,linux/arm64"
BUILDER="workshop-publish"
CONFIRM="${CONFIRM:-no}"
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --yes) CONFIRM=yes ;;
    -h | --help)
      sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) ARGS+=("$arg") ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
have docker || die "docker is required."
docker buildx version >/dev/null 2>&1 || die "docker buildx is required (brew install docker-buildx, then link the plugin)."
docker info >/dev/null 2>&1 || die "The Docker daemon is not reachable."

"$CATALOG" validate >/dev/null
VERSIONS=()
while IFS= read -r v; do
  VERSIONS+=("$v")
done < <(select_versions "${ARGS[@]+"${ARGS[@]}"}")
((${#VERSIONS[@]} > 0)) || exit 1 # select_versions already said why

REPO="$(image_repo)"
info "target: $REPO  (${#VERSIONS[@]} version(s): ${VERSIONS[*]})"

# --- Guard: a published image must trace back to a commit -----------------------------------------
if [[ "${ALLOW_DIRTY:-0}" != 1 ]]; then
  git -C "$ROOT_DIR" rev-parse --verify --quiet HEAD >/dev/null ||
    die "The repo has no commit yet, so the revision label would be 'unknown'. Commit first (ALLOW_DIRTY=1 only for tests)."
  [[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] ||
    die "The working tree has uncommitted changes. Commit them first, so the images match a commit (ALLOW_DIRTY=1 only for tests)."
  git -C "$ROOT_DIR" rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1 ||
    warn "HEAD is not on a pushed branch: the revision label points at a commit GitHub does not have yet."
fi
ok "working tree matches revision $(revision | cut -c1-12)"

# --- Guard: logged in ---------------------------------------------------------------------------------
if [[ "$REGISTRY" == ghcr.io ]]; then
  grep -qs '"ghcr.io"' "${DOCKER_CONFIG:-$HOME/.docker}/config.json" ||
    die "Not logged in to ghcr.io. Run: docker login ghcr.io -u <github-user>  (password: a classic token with write:packages)"
  ok "docker has credentials for ghcr.io"
fi

# --- Guard: tags are immutable ------------------------------------------------------------------------
tag_state() { # <ref> -> prints exists | absent | unknown:<message>
  local out
  if out="$(docker buildx imagetools inspect "$1" 2>&1)"; then
    printf 'exists'
    return 0
  fi
  case "$out" in
    *"not found"* | *"NOT_FOUND"* | *"MANIFEST_UNKNOWN"* | *"NAME_UNKNOWN"* | *"manifest unknown"* | *"name unknown"*) printf 'absent' ;;
    *) printf 'unknown:%s' "$(printf '%s' "$out" | tail -1)" ;;
  esac
}

EXISTING=()
for v in "${VERSIONS[@]}"; do
  state="$(tag_state "$REPO:$v")"
  case "$state" in
    exists) EXISTING+=("$v") ;;
    absent) ;;
    *) die "Cannot tell whether $REPO:$v exists (${state#unknown:}). Not publishing." ;;
  esac
done
if ((${#EXISTING[@]} > 0)); then
  die "Already published, and tags are immutable: ${EXISTING[*]}. Nothing was pushed. Use 'make teardown' to wipe versions first, or publish only new versions."
fi
ok "none of the tags exists yet"

# --- Builder with multi-platform support --------------------------------------------------------------
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  info "creating the buildx builder '$BUILDER'"
  docker buildx create --name "$BUILDER" --driver docker-container --driver-opt network=host >/dev/null
fi
docker buildx inspect "$BUILDER" --bootstrap >/dev/null

# --- Build (and push when confirmed) ------------------------------------------------------------------
for v in "${VERSIONS[@]}"; do
  build_args "$v"
  if [[ "$CONFIRM" == yes ]]; then
    info "building and pushing $REPO:$v ($PLATFORMS)"
    # No provenance/SBOM attestations: they would add extra entries to the index and the manifest must hold exactly the two platforms
    docker buildx build "$ROOT_DIR/app" --builder "$BUILDER" --platform "$PLATFORMS" \
      --provenance=false --sbom=false "${BUILD_ARGS[@]}" --tag "$REPO:$v" --push --quiet >/dev/null
  else
    info "building $REPO:$v for $PLATFORMS (not pushing)"
    docker buildx build "$ROOT_DIR/app" --builder "$BUILDER" --platform "$PLATFORMS" \
      --provenance=false --sbom=false "${BUILD_ARGS[@]}" --output type=cacheonly --quiet >/dev/null
  fi
done

if [[ "$CONFIRM" != yes ]]; then
  printf '\nDry run: everything checks out and builds for %s, nothing was pushed.\n' "$PLATFORMS"
  printf 'To push: make publish VERSION=%s CONFIRM=yes\n' "${ARGS[*]}"
  exit 0
fi

# --- Verify what was pushed ---------------------------------------------------------------------------
printf '\n'
FAILED=0
for v in "${VERSIONS[@]}"; do
  raw="$(docker buildx imagetools inspect "$REPO:$v" --raw)"
  digest="$(docker buildx imagetools inspect "$REPO:$v" 2>/dev/null | awk '/^Digest:/ {print $2; exit}')"
  platforms="$(printf '%s' "$raw" | tr -d ' \n' | grep -o '"architecture":"[a-z0-9]*","os":"[a-z]*"' | sort | tr '\n' ' ')"
  count="$(printf '%s' "$raw" | tr -d ' \n' | grep -o '"digest":"sha256' | wc -l | tr -d ' ')"
  if printf '%s' "$platforms" | grep -q '"architecture":"amd64","os":"linux"' &&
    printf '%s' "$platforms" | grep -q '"architecture":"arm64","os":"linux"' && [[ "$count" == 2 ]]; then
    printf ' ok  %s:%s  %s  [linux/amd64 linux/arm64]\n' "$REPO" "$v" "$digest"
  else
    printf 'FAIL %s:%s  %s  platforms=%s manifests=%s\n' "$REPO" "$v" "$digest" "$platforms" "$count"
    FAILED=1
  fi
done
((FAILED == 0)) || die "A pushed manifest does not hold exactly linux/amd64 and linux/arm64."

if [[ "$REGISTRY" == ghcr.io ]]; then
  cat <<EOF

Next, by hand (it cannot be done through the API): make the package public so attendees can pull it anonymously.
  user account:  https://github.com/users/$OWNER/packages/container/$IMAGE_BASENAME/settings
  organization:  https://github.com/orgs/$OWNER/packages/container/$IMAGE_BASENAME/settings
  -> "Danger Zone" -> Change visibility -> Public
Then check it from a machine that is not logged in:  docker buildx imagetools inspect $REPO:${VERSIONS[0]}
EOF
fi
