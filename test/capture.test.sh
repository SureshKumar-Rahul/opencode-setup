#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected '$3', got '$2'"
    fail=1
  fi
}

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

SRC="$SCRATCH/live"
DEST="$SCRATCH/repo"
PERSONAL="$SCRATCH/personal"
mkdir -p "$SRC/skills/mine" "$SRC/node_modules/junk" "$SRC/hook" "$DEST/opencode" "$PERSONAL"

cat > "$SRC/opencode.jsonc" <<'JSON'
{
  "model": "scads/private-choice",
  "instructions": ["AGENTS.md"],
  "references": {"docs": {"path": "~/private/docs"}},
  "plugin": ["opencode-damage-control", "opencode-mem"],
  "provider": {
    "scads": {"options": {"baseURL": "http://127.0.0.1:4141/v1"}},
    "secretbox": {"options": {"baseURL": "http://secretbox:8080/v1"}}
  }
}
JSON
echo '{}' > "$SRC/dcp.jsonc"
echo 'hooks: []' > "$SRC/hook/hooks.yaml"
echo 'personal skill' > "$SRC/skills/mine/SKILL.md"
echo 'my notes' > "$SRC/AGENTS.md"
echo 'junk' > "$SRC/node_modules/junk/index.js"
echo 'old' > "$SRC/opencode.jsonc.bak.20260101-000000"

OPENCODE_SETUP_DEST="$DEST" "$REPO/capture.sh" --src "$SRC" --personal-dir "$PERSONAL" >/dev/null
check "capture succeeds" "$?" "0"

check "shared config captured" "$([ -f "$DEST/opencode/opencode.jsonc" ] && echo yes || echo no)" "yes"
check "shared sidecar captured" "$([ -f "$DEST/opencode/hook/hooks.yaml" ] && echo yes || echo no)" "yes"
check "skills routed to personal" "$([ -f "$PERSONAL/skills/mine/SKILL.md" ] && echo yes || echo no)" "yes"
check "AGENTS.md routed to personal" "$([ -f "$PERSONAL/AGENTS.md" ] && echo yes || echo no)" "yes"
check "skills NOT in shared" "$([ -d "$DEST/opencode/skills" ] && echo present || echo absent)" "absent"
check "AGENTS.md NOT in shared" "$([ -f "$DEST/opencode/AGENTS.md" ] && echo present || echo absent)" "absent"
check "node_modules excluded" "$([ -d "$DEST/opencode/node_modules" ] && echo present || echo absent)" "absent"
check "node_modules not personal either" "$([ -d "$PERSONAL/node_modules" ] && echo present || echo absent)" "absent"
check "backups excluded" "$(find "$DEST" "$PERSONAL" -name '*.bak.*' | wc -l)" "0"

# Host-specific keys must be stripped from the shared base.
check "model stripped" \
  "$(python3 -c 'import json,sys; print("model" in json.load(open(sys.argv[1])))' "$DEST/opencode/opencode.jsonc")" \
  "False"
check "references stripped" \
  "$(python3 -c 'import json,sys; print("references" in json.load(open(sys.argv[1])))' "$DEST/opencode/opencode.jsonc")" \
  "False"
check "private provider stripped" \
  "$(python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))["provider"]))' "$DEST/opencode/opencode.jsonc")" \
  "['scads']"
check "mem plugin stripped" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plugin"])' "$DEST/opencode/opencode.jsonc")" \
  "['opencode-damage-control']"

# A secret anywhere in the live config must abort the whole capture.
CLEAN_DEST="$SCRATCH/repo2"
CLEAN_PERSONAL="$SCRATCH/personal2"
mkdir -p "$CLEAN_DEST/opencode" "$CLEAN_PERSONAL"
echo 'sk-abcdefghijklmnopqrstuvwxyz012345' > "$SRC/.leaked-key"
OPENCODE_SETUP_DEST="$CLEAN_DEST" "$REPO/capture.sh" --src "$SRC" --personal-dir "$CLEAN_PERSONAL" >/dev/null 2>&1
check "aborts on a secret" "$?" "1"
check "writes nothing when aborting" "$(find "$CLEAN_DEST/opencode" "$CLEAN_PERSONAL" -type f | wc -l)" "0"

exit "$fail"
