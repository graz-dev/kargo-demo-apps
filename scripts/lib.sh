# shellcheck shell=bash
# Shared helpers for build, publish and teardown. Source this file; do not execute it.
# Bash 3.2 compatible (macOS default).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT_DIR/scripts/catalog.sh"

info() { printf '==> %s\n' "$*"; }
ok() { printf ' ok  %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
die() {
  printf 'ERROR %s\n' "$*" >&2
  exit 1
}

# Owner of the origin remote (github.com/<owner>/<repo>), lower case as registries require
origin_owner() {
  local url
  url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
  printf '%s' "$url" | sed -nE 's#^(git@github\.com:|https?://github\.com/)([^/]+)/.*#\2#p' | tr '[:upper:]' '[:lower:]'
}

# URL of this repository (OCI source label), from the origin remote
source_url() {
  local url
  url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
  url="${url%.git}"
  case "$url" in
    git@github.com:*) url="https://github.com/${url#git@github.com:}" ;;
  esac
  printf '%s' "$url"
}

# Commit the images are built from, or "unknown" before the first commit
revision() {
  local rev
  rev="$(git -C "$ROOT_DIR" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
  printf '%s' "${rev:-unknown}"
}

# Where the images live. Overridable for tests: IMAGE_REGISTRY, IMAGE_OWNER, IMAGE_NAME.
REGISTRY="${IMAGE_REGISTRY:-ghcr.io}"
OWNER="${IMAGE_OWNER:-$(origin_owner)}"
IMAGE_BASENAME="${IMAGE_NAME:-$("$CATALOG" image)}"
image_repo() {
  [[ -n "$OWNER" ]] || die "Cannot tell the image owner: the origin remote is not a github.com URL. Set IMAGE_OWNER."
  printf '%s/%s/%s' "$REGISTRY" "$OWNER" "$IMAGE_BASENAME"
}

# Fills the global array BUILD_ARGS with the --build-arg flags of a catalog version
build_args() {
  local v="$1" created
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # shellcheck disable=SC2034 # read by the scripts that source this file
  BUILD_ARGS=(
    --build-arg "APP_VERSION=$v"
    --build-arg "THEME=$("$CATALOG" get "$v" theme)"
    --build-arg "MESSAGE=$("$CATALOG" get "$v" message)"
    --build-arg "BROKEN=$("$CATALOG" get "$v" broken)"
    --build-arg "TITLE=$("$CATALOG" get "$v" title)"
    --build-arg "DESCRIPTION=$("$CATALOG" get "$v" notes)"
    --build-arg "SOURCE=$(source_url)"
    --build-arg "REVISION=$(revision)"
    --build-arg "CREATED=$created"
  )
}

# Resolves "all" or a list of versions to the versions to act on, failing for unknown ones
select_versions() {
  local v
  if [[ "${1:-}" == all ]]; then
    "$CATALOG" versions
    return 0
  fi
  [[ $# -gt 0 ]] || die "Say which version: a version from releases.yaml, or 'all'."
  for v in "$@"; do
    "$CATALOG" get "$v" theme >/dev/null 2>&1 || die "Version '$v' is not in releases.yaml."
    printf '%s\n' "$v"
  done
}
