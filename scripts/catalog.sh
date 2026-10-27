#!/usr/bin/env bash
# Reads releases.yaml (strict, flat format: see the header of that file).
#
#   scripts/catalog.sh image                  name of the image (no registry, no owner)
#   scripts/catalog.sh versions               every version, in file order
#   scripts/catalog.sh get <version> <field>  title | theme | message | broken | notes
#   scripts/catalog.sh live <version>         true for a version published by hand during the workshop, else false
#   scripts/catalog.sh list                   a table
#   scripts/catalog.sh validate               fails when the catalog breaks the rules
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${CATALOG_FILE:-$ROOT_DIR/releases.yaml}"
THEMES="slate blue green purple red teal orange"
FIELDS="version title theme message broken notes"

die() {
  printf 'catalog: %s\n' "$*" >&2
  exit 1
}

unquote() { sed -E "s/^[[:space:]]*['\"]?//; s/['\"]?[[:space:]]*$//"; }

cmd_image() {
  awk '/^image:/ { sub(/^image:[ \t]*/, ""); print; exit }' "$FILE" | unquote
}

cmd_versions() {
  awk '/^  - version:/ { sub(/^  - version:[ \t]*/, ""); print }' "$FILE" | unquote
}

cmd_get() {
  local want="$1" key="$2" out
  out="$(awk -v want="$want" -v key="$key" '
    /^  - version:/ { cur = $0; sub(/^  - version:[ \t]*/, "", cur); gsub(/["\047]/, "", cur); sub(/[ \t]+$/, "", cur); next }
    cur == want && index($0, "    " key ":") == 1 { v = $0; sub("^    " key ":[ \t]*", "", v); print v; found = 1; exit }
    END { exit !found }
  ' "$FILE")" || die "no '$key' for version '$want' in $FILE"
  printf '%s\n' "$out" | unquote
}

# live is optional: absent means false
cmd_live() {
  local out
  out="$(cmd_get "$1" live 2>/dev/null || true)"
  printf '%s\n' "${out:-false}"
}

cmd_list() {
  local v
  printf '%-8s %-8s %-7s %-5s %s\n' VERSION THEME BROKEN LIVE TITLE
  for v in $(cmd_versions); do
    printf '%-8s %-8s %-7s %-5s %s\n' "$v" "$(cmd_get "$v" theme)" "$(cmd_get "$v" broken)" "$(cmd_live "$v")" "$(cmd_get "$v" title)"
  done
}

cmd_validate() {
  local image v f val seen=" " broken_count=0
  image="$(cmd_image)"
  [[ "$image" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || die "image name '$image' is not a valid repository name"
  [[ -n "$(cmd_versions)" ]] || die "no versions in $FILE"
  for v in $(cmd_versions); do
    [[ "$v" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "version '$v' is not plain SemVer (no 'v' prefix, no pre-release)"
    case "$seen" in *" $v "*) die "version '$v' is listed twice" ;; esac
    seen="$seen$v "
    for f in $FIELDS; do
      [[ "$f" == version ]] && continue
      val="$(cmd_get "$v" "$f")"
      [[ -n "$val" ]] || die "$v: '$f' is empty"
    done
    case " $THEMES " in *" $(cmd_get "$v" theme) "*) ;; *) die "$v: unknown theme '$(cmd_get "$v" theme)' (use: $THEMES)" ;; esac
    case "$(cmd_get "$v" broken)" in
      true) broken_count=$((broken_count + 1)) ;;
      false) ;;
      *) die "$v: broken must be true or false" ;;
    esac
    case "$(cmd_live "$v")" in true | false) ;; *) die "$v: live must be true or false" ;; esac
    [[ "$(cmd_get "$v" message)" =~ ^[A-Za-z0-9\ .,!?:\;\'\(\)/_-]+$ ]] ||
      die "$v: message has characters outside letters, digits, spaces and . , ! ? : ; ' ( ) / _ -"
  done
  ((broken_count >= 1)) || die "the catalog needs at least one broken version (Lab 4)"
  printf 'catalog ok: %s version(s), %s broken\n' "$(cmd_versions | wc -l | tr -d ' ')" "$broken_count"
}

case "${1:-}" in
  image) cmd_image ;;
  versions) cmd_versions ;;
  get)
    (($# == 3)) || die "usage: catalog.sh get <version> <field>"
    cmd_get "$2" "$3"
    ;;
  live)
    (($# == 2)) || die "usage: catalog.sh live <version>"
    cmd_live "$2"
    ;;
  list) cmd_list ;;
  validate) cmd_validate ;;
  *) die "usage: catalog.sh image|versions|get <version> <field>|live <version>|list|validate" ;;
esac
