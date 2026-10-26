#!/usr/bin/env bash
# Builds catalog versions as local images "<image>:<version>" for this machine's architecture.
# There is never a "latest" tag and nothing is pushed.
#
#   scripts/build.sh [version ...]      default: every version in releases.yaml
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

"$CATALOG" validate >/dev/null
image="$("$CATALOG" image)"

if (($# == 0)); then
  set -- all
fi
VERSIONS=()
while IFS= read -r v; do
  VERSIONS+=("$v")
done < <(select_versions "$@")
((${#VERSIONS[@]} > 0)) || exit 1 # select_versions already said why

for v in "${VERSIONS[@]}"; do
  info "building $image:$v"
  build_args "$v"
  docker build "$ROOT_DIR/app" --tag "$image:$v" "${BUILD_ARGS[@]}" --quiet >/dev/null
done
