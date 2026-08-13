#!/usr/bin/env bash
# One-step opencode setup: config tree, host overlay, credential gateway.
#
#   ./install.sh [--host NAME] [--profile base|personal] [--personal-dir PATH]
#                [--no-gateway] [--install-opencode] [--dry-run]
#
# Idempotent: run it again after every git pull.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/opencode"
# uname -n is coreutils; the hostname binary is not installed by default on Arch.
HOST="$(uname -n)"
PROFILE="base"
PERSONAL_DIR="${OPENCODE_PERSONAL_DIR:-}"
DO_GATEWAY=1
DO_INSTALL_OPENCODE=0
DRY_RUN=0
MARK_START="# >>> local-opencode managed >>>"
MARK_END="# <<< local-opencode managed <<<"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --personal-dir) PERSONAL_DIR="$2"; shift 2 ;;
    --no-gateway) DO_GATEWAY=0; shift ;;
    --install-opencode) DO_INSTALL_OPENCODE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "install.sh: unknown flag '$1'" >&2; usage 2 ;;
  esac
done

case "$PROFILE" in
  base|personal) ;;
  *) echo "install.sh: --profile must be 'base' or 'personal'" >&2; exit 2 ;;
esac

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY_RUN" -eq 1 ]; then say "would: $*"; else "$@"; fi; }

# --- preflight ------------------------------------------------------------
missing=()
command -v python3 >/dev/null || missing+=("python3        (pacman -S python)")
command -v git >/dev/null || missing+=("git            (pacman -S git)")
command -v curl >/dev/null || missing+=("curl           (pacman -S curl)")

if command -v node >/dev/null; then
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$node_major" -ge 20 ] || missing+=("nodejs >= 20   (found $node_major; pacman -S nodejs)")
else
  missing+=("nodejs >= 20   (pacman -S nodejs)")
fi

if ! command -v opencode >/dev/null; then
  if [ "$DO_INSTALL_OPENCODE" -eq 1 ]; then
    say "installing opencode from opencode.ai..."
    run bash -c 'curl -fsSL https://opencode.ai/install | bash'
  else
    missing+=("opencode       (rerun with --install-opencode, or see https://opencode.ai)")
  fi
fi

if [ "${#missing[@]}" -gt 0 ]; then
  say "install.sh: missing prerequisites:"
  printf '  - %s\n' "${missing[@]}"
  exit 1
fi

# --- resolve the host overlay --------------------------------------------
# Personal overlays win, so machine-specific settings never need to live in
# the shared repo.
if [ -n "$PERSONAL_DIR" ] && [ -f "$PERSONAL_DIR/hosts/$HOST.json" ]; then
  OVERLAY="$PERSONAL_DIR/hosts/$HOST.json"
elif [ -f "$REPO/hosts/$HOST.json" ]; then
  OVERLAY="$REPO/hosts/$HOST.json"
else
  OVERLAY="$REPO/hosts/example.json"
  say "no overlay for '$HOST', falling back to hosts/example.json"
fi

if [ "$PROFILE" = "personal" ] && { [ -z "$PERSONAL_DIR" ] || [ ! -d "$PERSONAL_DIR" ]; }; then
  say "install.sh: --profile personal needs --personal-dir PATH or OPENCODE_PERSONAL_DIR" >&2
  exit 1
fi

# --- stage the config -----------------------------------------------------
staged="$(mktemp -d)"
trap 'rm -rf "$staged"' EXIT

cp -r "$REPO/opencode/." "$staged/"
if [ "$PROFILE" = "personal" ]; then
  # hosts/ holds overlays, not config files, so it must not be installed.
  for entry in "$PERSONAL_DIR"/*; do
    [ -e "$entry" ] || continue
    [ "$(basename "$entry")" = "hosts" ] && continue
    cp -r "$entry" "$staged/"
  done
fi

python3 "$REPO/lib/merge.py" "$REPO/opencode/opencode.jsonc" "$OVERLAY" > "$staged/opencode.jsonc" || {
  say "install.sh: overlay merge failed for $OVERLAY" >&2
  exit 1
}
python3 -m json.tool "$staged/opencode.jsonc" > /dev/null || {
  say "install.sh: merge produced invalid JSON" >&2
  exit 1
}

# --- compare, back up, install -------------------------------------------
# Only files this installer manages are compared; anything else already in the
# config directory (node_modules, logs, local plugins) is left alone.
changed=0
while IFS= read -r -d '' file; do
  rel="${file#"$staged"/}"
  if ! cmp -s "$file" "$CONFIG_DIR/$rel"; then
    changed=1
    break
  fi
done < <(find "$staged" -type f -print0)

if [ "$changed" -eq 0 ]; then
  say "config: no changes"
else
  if [ -d "$CONFIG_DIR" ]; then
    BACKUP="$CONFIG_DIR/.backup-$(date +%Y%m%d-%H%M%S)"
    run mkdir -p "$BACKUP"
    while IFS= read -r -d '' file; do
      rel="${file#"$staged"/}"
      if [ -f "$CONFIG_DIR/$rel" ]; then
        run mkdir -p "$BACKUP/$(dirname "$rel")"
        run cp "$CONFIG_DIR/$rel" "$BACKUP/$rel"
      fi
    done < <(find "$staged" -type f -print0)
    say "config: backed up replaced files to $BACKUP"
  fi
  run mkdir -p "$CONFIG_DIR"
  run cp -r "$staged/." "$CONFIG_DIR/"
  say "config: written to $CONFIG_DIR"
fi

# --- plugin dependencies --------------------------------------------------
if [ "$DRY_RUN" -eq 0 ] && [ -f "$CONFIG_DIR/package.json" ] && command -v npm >/dev/null; then
  (cd "$CONFIG_DIR" && npm install --silent >/dev/null 2>&1) || say "warning: npm install failed" >&2
fi

# --- gateway --------------------------------------------------------------
if [ "$DO_GATEWAY" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would: sudo $REPO/gateway/install-gateway.sh"
  elif sudo "$REPO/gateway/install-gateway.sh"; then
    :
  else
    say "install.sh: gateway installation failed or sudo was refused" >&2
    exit 1
  fi
fi

# --- shell wiring ---------------------------------------------------------
case "${SHELL##*/}" in
  zsh) RC="$HOME/.zshrc" ;;
  *) RC="$HOME/.bashrc" ;;
esac

if [ "$DRY_RUN" -eq 0 ]; then
  touch "$RC"
  MARK_START="$MARK_START" MARK_END="$MARK_END" python3 - "$RC" <<'PY'
import os
import sys

rc = sys.argv[1]
start, end = os.environ["MARK_START"], os.environ["MARK_END"]
block = "\n".join([
    start,
    "# Managed by opencode-setup. Edit the repo, not this block.",
    "# The SCADS key lives in the oc-gateway daemon; nothing here holds it.",
    "alias oc-unlock='oc-key unlock'",
    end,
])
text = open(rc).read()
if start in text and end in text:
    head, rest = text.split(start, 1)
    _, tail = rest.split(end, 1)
    new = head + block + tail
else:
    new = text.rstrip("\n") + "\n\n" + block + "\n"
if new != text:
    open(rc, "w").write(new)
    print(f"shell: managed block updated in {rc}")
else:
    print(f"shell: managed block already current in {rc}")
PY
fi

# --- leak cleanup ---------------------------------------------------------
for stale in "$CONFIG_DIR/.scads-embed-key" "$CONFIG_DIR/keyring-auth.ts"; do
  if [ -e "$stale" ]; then
    run rm -f "$stale"
    say "cleanup: removed $stale"
  fi
done

if command -v secret-tool >/dev/null; then
  if [ "$DRY_RUN" -eq 0 ] && secret-tool lookup service scads-api account default >/dev/null 2>&1; then
    secret-tool clear service scads-api account default || true
    say "cleanup: cleared the scads-api keyring entry"
  fi
else
  say "cleanup: libsecret absent, skipping the keyring clear"
fi

for rcfile in "$HOME/.zshrc" "$HOME/.bashrc"; do
  if [ -f "$rcfile" ] && grep -q 'SCADS_API_KEY' "$rcfile"; then
    say "WARNING: $rcfile still references SCADS_API_KEY. That wrapper puts the key"
    say "         in the agent's environment. Remove it; the gateway replaces it."
  fi
done

# --- postflight -----------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
  python3 -m json.tool "$CONFIG_DIR/opencode.jsonc" > /dev/null || {
    say "postflight: installed config is not valid JSON" >&2
    exit 1
  }
  if [ "$DO_GATEWAY" -eq 1 ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4141/v1/models || true)"
    say "gateway: HTTP $code (401 means locked, which is expected before oc-key unlock)"
  fi
fi

if [ "$changed" -eq 0 ]; then
  say "install.sh: no changes"
else
  say "install.sh: done"
fi
if [ "$DO_GATEWAY" -eq 1 ]; then
  say "next: oc-key unlock   (new group needs a fresh login, or use: sg ocgw-admin)"
fi
