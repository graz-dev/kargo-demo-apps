#!/usr/bin/env bash
# Deletes published image versions from GHCR, so the workshop can be redone from scratch.
# Guarded: without --yes (or CONFIRM=yes) it only lists what it would delete.
#
#   scripts/teardown.sh <version|all> [--yes]
#
# A version means its tag, the multi-arch index and the per-platform manifests it points to (GHCR lists each
# manifest as a package version). "all" deletes every version of the package. The package itself is never
# deleted here, but GitHub may remove a package whose last version is gone: check it is still public afterwards.
#
# Credentials: GITHUB_TOKEN, a classic token with read:packages and delete:packages (the API cannot use anything
# weaker). When GITHUB_TOKEN is not set, the token saved by your `docker login <registry>` is used, so the token you
# publish with just needs the delete:packages scope as well. A public package version with more than 5,000
# downloads cannot be deleted through the API.
# Needs python3. Overridable for tests: IMAGE_REGISTRY, IMAGE_OWNER, IMAGE_NAME, GITHUB_API_URL.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIRM="${CONFIRM:-no}"
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --yes) CONFIRM=yes ;;
    -h | --help)
      sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) ARGS+=("$arg") ;;
  esac
done

command -v python3 >/dev/null || die "python3 is required."
command -v docker >/dev/null || die "docker is required (to read the manifests)."
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  GITHUB_TOKEN="$(docker_login_token "$REGISTRY")"
  [[ -z "$GITHUB_TOKEN" ]] || info "GITHUB_TOKEN is not set: using the token saved by 'docker login $REGISTRY'"
fi
[[ -n "$GITHUB_TOKEN" ]] ||
  die "No token: set GITHUB_TOKEN to a classic token with read:packages and delete:packages, or run 'docker login $REGISTRY' with such a token."
export GITHUB_TOKEN
if [[ "$REGISTRY" != ghcr.io && -z "${GITHUB_API_URL:-}" ]]; then
  die "teardown works on ghcr.io packages only (registry is '$REGISTRY')."
fi

"$CATALOG" validate >/dev/null
[[ "${ARGS[0]:-}" == all ]] || select_versions "${ARGS[@]+"${ARGS[@]}"}" >/dev/null
WANT="${ARGS[*]:-}"
[[ -n "$WANT" ]] || die "Say which version: a version from releases.yaml, or 'all'."

REPO="$(image_repo)"
PY="$ROOT_DIR/scripts/ghcr-packages.py"
info "package: $OWNER/$IMAGE_BASENAME  (selection: $WANT)"

LIST="$(python3 -I "$PY" list "$OWNER" "$IMAGE_BASENAME")"
[[ -n "$LIST" ]] || {
  ok "the package has no versions: nothing to delete"
  exit 0
}

# Digests of the manifests behind the selected tags
CHILDREN=" "
if [[ "$WANT" != all ]]; then
  for v in $WANT; do
    if raw="$(docker buildx imagetools inspect "$REPO:$v" --raw 2>/dev/null)"; then
      for d in $(printf '%s' "$raw" | grep -o '"digest": *"sha256:[0-9a-f]*"' | grep -o 'sha256:[0-9a-f]*'); do
        CHILDREN="$CHILDREN$d "
      done
    else
      warn "cannot read the manifest of $REPO:$v: only the versions tagged $v will be selected"
    fi
  done
fi

SELECT=()
while IFS=$'\t' read -r id name tags; do
  pick=0
  if [[ "$WANT" == all ]]; then
    pick=1
  else
    for v in $WANT; do
      case ",$tags," in *",$v,"*) pick=1 ;; esac
    done
    case "$CHILDREN" in *" $name "*) pick=1 ;; esac
  fi
  ((pick == 0)) || SELECT+=("$id"$'\t'"$name"$'\t'"$tags")
done <<<"$LIST"

if ((${#SELECT[@]} == 0)); then
  ok "no version of the package matches '$WANT': nothing to delete"
  exit 0
fi

printf '\nVersions that will be deleted from %s/%s:\n' "$OWNER" "$IMAGE_BASENAME"
printf '  %-12s %-20s %s\n' ID DIGEST TAGS
for row in "${SELECT[@]}"; do
  IFS=$'\t' read -r id name tags <<<"$row"
  printf '  %-12s %-20s %s\n' "$id" "${name:0:19}" "${tags:--}"
done

if [[ "$CONFIRM" != yes ]]; then
  printf '\nDry run: nothing was deleted. To delete: make teardown VERSION=%s CONFIRM=yes\n' "$WANT"
  exit 0
fi

printf '\n'
for row in "${SELECT[@]}"; do
  IFS=$'\t' read -r id _ _ <<<"$row"
  python3 -I "$PY" delete "$OWNER" "$IMAGE_BASENAME" "$id"
  ok "deleted version $id"
done
