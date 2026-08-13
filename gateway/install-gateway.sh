#!/usr/bin/env bash
# Install the oc-gateway daemon, its systemd unit, and the oc-key CLI.
# Requires root. Idempotent: safe to re-run after every git pull.
set -euo pipefail

PREFIX="/usr/local"
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help) echo "usage: install-gateway.sh [--prefix /usr/local]"; exit 0 ;;
    *) echo "install-gateway.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || {
  echo "install-gateway.sh: must run as root (use sudo)" >&2
  exit 1
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_USER="${SUDO_USER:-}"
[ -n "$TARGET_USER" ] || {
  echo "install-gateway.sh: run via sudo so the invoking user can be added to ocgw-admin" >&2
  exit 1
}

NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || { echo "install-gateway.sh: node is not installed" >&2; exit 1; }

# --- accounts -------------------------------------------------------------
getent group ocgw-admin >/dev/null || groupadd --system ocgw-admin
getent passwd ocgw >/dev/null ||
  useradd --system --no-create-home --shell /usr/bin/nologin --gid ocgw-admin ocgw
gpasswd --add "$TARGET_USER" ocgw-admin >/dev/null

# --- files ----------------------------------------------------------------
install -d -m 0755 "$PREFIX/lib/oc-gateway/lib"
install -m 0644 "$HERE/oc-gateway.mjs" "$PREFIX/lib/oc-gateway/oc-gateway.mjs"
install -m 0644 "$HERE"/lib/*.mjs "$PREFIX/lib/oc-gateway/lib/"

# Root-owned on purpose: the human user must not be able to rewrite the CLI
# that handles the key.
install -m 0755 -o root -g root "$HERE/oc-key" "$PREFIX/bin/oc-key"

# The unit ships with /usr/bin/node and the default prefix; rewrite ExecStart
# so a different node path or --prefix still produces a working unit.
sed "s#^ExecStart=.*#ExecStart=$NODE_BIN $PREFIX/lib/oc-gateway/oc-gateway.mjs#" \
  "$HERE/oc-gateway.service" > /etc/systemd/system/oc-gateway.service
chmod 0644 /etc/systemd/system/oc-gateway.service

# --- service --------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now oc-gateway.service
systemctl restart oc-gateway.service

if ! systemctl is-active --quiet oc-gateway.service; then
  echo "install-gateway.sh: service failed to start" >&2
  journalctl -u oc-gateway -n 20 --no-pager >&2
  exit 1
fi

echo "oc-gateway installed and running on 127.0.0.1:4141"
echo "Group membership takes effect at next login. For this shell: sg ocgw-admin"
echo "Next: oc-key unlock"
