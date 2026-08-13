#!/usr/bin/env bash
# Exercises the config half of install.sh against a scratch HOME.
# The gateway half needs root, so it is skipped here with --no-gateway.
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

json_get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
CONF="$SCRATCH/home/.config/opencode"
mkdir -p "$SCRATCH/home"

# --- base profile, unknown host -> example overlay -------------------------
out="$(HOME="$SCRATCH/home" "$REPO/install.sh" --host nosuchmachine --no-gateway 2>&1)"
check "runs clean" "$?" "0"
check "unknown host falls back" "$(echo "$out" | grep -c 'hosts/example.json')" "1"
check "config written" "$([ -f "$CONF/opencode.jsonc" ] && echo yes || echo no)" "yes"
check "valid json" "$(python3 -m json.tool "$CONF/opencode.jsonc" >/dev/null 2>&1 && echo yes || echo no)" "yes"
check "example model applied" "$(json_get "$CONF/opencode.jsonc" model)" "scads/meta-llama/Llama-3.3-70B-Instruct"
check "points at the gateway" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["provider"]["scads"]["options"]["baseURL"])' "$CONF/opencode.jsonc")" \
  "http://127.0.0.1:4141/v1"
check "placeholder api key" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["provider"]["scads"]["options"]["apiKey"])' "$CONF/opencode.jsonc")" \
  "local"
check "sidecar config copied" "$([ -f "$CONF/hook/hooks.yaml" ] && echo yes || echo no)" "yes"

# --- privacy regression: a base install carries no personal content --------
check "no skills" "$([ -d "$CONF/skills" ] && echo present || echo absent)" "absent"
check "no agents" "$([ -d "$CONF/agents" ] && echo present || echo absent)" "absent"
check "no commands" "$([ -d "$CONF/commands" ] && echo present || echo absent)" "absent"
check "no AGENTS.md" "$([ -f "$CONF/AGENTS.md" ] && echo present || echo absent)" "absent"
check "no mem config" "$([ -f "$CONF/opencode-mem.jsonc" ] && echo present || echo absent)" "absent"
check "no overlays installed" "$([ -d "$CONF/hosts" ] && echo present || echo absent)" "absent"

# --- idempotency -----------------------------------------------------------
second="$(HOME="$SCRATCH/home" "$REPO/install.sh" --host nosuchmachine --no-gateway 2>&1)"
check "idempotent" "$(echo "$second" | grep -c 'install.sh: no changes')" "1"
check "no backup on a no-op" "$(find "$CONF" -maxdepth 1 -name '.backup-*' | wc -l)" "0"

# --- personal profile ------------------------------------------------------
PERSONAL="$SCRATCH/personal"
mkdir -p "$PERSONAL/skills/mine" "$PERSONAL/hosts"
echo 'my skill' > "$PERSONAL/skills/mine/SKILL.md"
echo 'my agents file' > "$PERSONAL/AGENTS.md"
cat > "$PERSONAL/hosts/nosuchmachine.json" <<'JSON'
{ "model": "scads/zai-org/GLM-5.2-FP8" }
JSON

HOME="$SCRATCH/home" "$REPO/install.sh" --host nosuchmachine --no-gateway \
  --profile personal --personal-dir "$PERSONAL" >/dev/null 2>&1
check "personal skills installed" "$([ -f "$CONF/skills/mine/SKILL.md" ] && echo yes || echo no)" "yes"
check "personal AGENTS.md installed" "$([ -f "$CONF/AGENTS.md" ] && echo yes || echo no)" "yes"
check "personal overlay wins" "$(json_get "$CONF/opencode.jsonc" model)" "scads/zai-org/GLM-5.2-FP8"
check "personal hosts dir not installed" "$([ -d "$CONF/hosts" ] && echo present || echo absent)" "absent"
check "backup made when changing" "$(find "$CONF" -maxdepth 1 -name '.backup-*' | wc -l)" "1"

# --- personal profile without a directory must fail ------------------------
HOME="$SCRATCH/home" "$REPO/install.sh" --host nosuchmachine --no-gateway --profile personal >/dev/null 2>&1
check "personal without dir fails" "$?" "1"

# --- dry run changes nothing ----------------------------------------------
DRYHOME="$SCRATCH/dry"
mkdir -p "$DRYHOME"
HOME="$DRYHOME" "$REPO/install.sh" --host nosuchmachine --no-gateway --dry-run >/dev/null 2>&1
check "dry run writes no config" "$([ -f "$DRYHOME/.config/opencode/opencode.jsonc" ] && echo present || echo absent)" "absent"

# --- bad flags -------------------------------------------------------------
HOME="$SCRATCH/home" "$REPO/install.sh" --profile nonsense --no-gateway >/dev/null 2>&1
check "rejects a bad profile" "$?" "2"

exit "$fail"
