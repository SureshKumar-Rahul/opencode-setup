#!/usr/bin/env bash
# Copy the live ~/.config/opencode back into the repos, splitting shared from
# personal so the shared repo never gains personal content.
#
#   ./capture.sh --personal-dir PATH
#
# Anything not on the SHARED list is treated as personal. That default is
# deliberate: the failure mode is "a colleague is missing a file", never
# "a colleague received your notes".
set -euo pipefail

REPO="${OPENCODE_SETUP_DEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SRC="$HOME/.config/opencode"
PERSONAL_DIR="${OPENCODE_PERSONAL_DIR:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --personal-dir) PERSONAL_DIR="$2"; shift 2 ;;
    --src) SRC="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "capture.sh: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

[ -d "$SRC" ] || { echo "capture.sh: $SRC does not exist" >&2; exit 1; }
[ -n "$PERSONAL_DIR" ] || { echo "capture.sh: --personal-dir PATH is required" >&2; exit 1; }

# Files that are safe for collaborators. Everything else goes to personal.
SHARED=(opencode.jsonc dcp.jsonc smart-title.jsonc tui.json package.json vision-model-image.txt hook)
EXCLUDE=(node_modules package-lock.json bun.lock .scads-embed-key keyring-auth.ts .git .gitignore logs)

SECRET_RE='(sk-[A-Za-z0-9_-]{16,}|hf_[A-Za-z0-9]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'

# Secret scan first: write nothing at all if anything key-shaped is present.
hits="$(grep -rIlE "$SECRET_RE" "$SRC" \
  --exclude-dir=node_modules --exclude-dir='.backup-*' --exclude-dir=.git 2>/dev/null || true)"
if [ -n "$hits" ]; then
  echo "capture.sh: key-shaped content found, refusing to write:" >&2
  printf '  %s\n' $hits >&2
  exit 1
fi

in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [ "$needle" = "$item" ] && return 0
  done
  return 1
}

mkdir -p "$REPO/opencode" "$PERSONAL_DIR"

shopt -s dotglob nullglob
for path in "$SRC"/*; do
  name="$(basename "$path")"
  case "$name" in
    .backup-*|*.bak|*.bak.*) continue ;;
  esac
  in_list "$name" "${EXCLUDE[@]}" && continue

  if in_list "$name" "${SHARED[@]}"; then
    cp -r "$path" "$REPO/opencode/"
    echo "shared:   $name"
  else
    cp -r "$path" "$PERSONAL_DIR/"
    echo "personal: $name"
  fi
done
shopt -u dotglob nullglob

# The captured opencode.jsonc is a live config carrying host-specific values.
# The shared base must not, so strip the machine-specific keys back out.
python3 - "$REPO/opencode/opencode.jsonc" <<'PY'
import json
import sys

path = sys.argv[1]
config = json.load(open(path))
for key in ("model", "instructions", "references"):
    config.pop(key, None)
config["plugin"] = [p for p in config.get("plugin", []) if p != "opencode-mem"]
for provider in list(config.get("provider", {})):
    if provider != "scads":
        del config["provider"][provider]
json.dump(config, open(path, "w"), indent=2)
open(path, "a").write("\n")
print("shared:   opencode.jsonc (host-specific keys stripped)")
PY

echo "capture.sh: done. Review 'git -C $REPO status' before committing."
