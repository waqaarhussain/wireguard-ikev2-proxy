#!/usr/bin/env bash
set -euo pipefail

BASE="/Wireguard"
EXITS_DB="$BASE/maps/exits.db"
EXITS_DIR="$BASE/exits"
CLIENT_DIR="$BASE/client"
SERVER_CONF="/etc/wireguard/wg0.conf"
SERVER_PUB="$(cat "$BASE/server/server_publickey")"
SERVER_IP="$(cat "$BASE/ikev2/server/server_id")"

mkdir -p "$CLIENT_DIR"

SLUG="${1:?Proxy slug required}"
RAW_NAME="${2:?Client name required}"
EXISTING="${3:-}"
DISPLAY="${4:-}"

python3 - "$SLUG" "$RAW_NAME" "$EXISTING" <<'VALIDATE'
import sys
slug, name, existing = sys.argv[1:]
if not slug or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in slug):
    sys.exit('Invalid proxy slug.')
if not name or len(name) > 64 or not name.isprintable() or any(c in name for c in '/\\|'):
    sys.exit('Use 1 to 64 printable characters, without slash, backslash or |, for the client name.')
if existing in ('.', '..') or any(c in existing for c in '/\\|\n\r'):
    sys.exit('Invalid existing profile name.')
VALIDATE

ENV_FILE="$EXITS_DIR/$SLUG.env"
[ -f "$ENV_FILE" ] || { echo "Exit not found"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
SAFE_LABEL="$(printf '%s' "$LABEL" | tr -cd '[:alnum:] ._()-' | cut -c1-64)"
FINAL="${RAW_NAME} - [${TYPE_TAG} - ${SAFE_LABEL:-$SLUG}]"
if [ -n "$EXISTING" ]; then
  FINAL="$EXISTING"
else
  ORIGINAL="$FINAL"
  N=2
  while [ -e "$CLIENT_DIR/$FINAL" ]; do
    FINAL="${ORIGINAL}-${N}"
    N=$((N+1))
  done
fi
DIR="$CLIENT_DIR/$FINAL"
CONF="$DIR/$FINAL.conf"
mkdir -p "$DIR"
chmod 700 "$DIR"
umask 077
python3 - "$DIR/.client-info.json" "$RAW_NAME" "$SLUG" <<'META'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({'client': sys.argv[2], 'exit': sys.argv[3]}) + '\n')
META

IP="$(awk -F'|' -v n="$FINAL" -v s="$SLUG" '$2==s && $3==n{print $1; exit}' "$BASE/maps/client_map.db")"
if [ -n "$IP" ]; then
  [ -s "$CONF" ] || { echo "Existing WireGuard config is missing: $CONF. Restore it from backup."; exit 1; }
else
USED="$(awk -F'|' '{print $1}' "$BASE/maps/client_map.db" | grep -Eo '10\.8\.0\.[0-9]+' | awk -F. '{print $4}' | sort -n | uniq || true)"
IP=""
for o in $(seq 2 254); do
  if ! echo "$USED" | grep -qx "$o"; then
    IP="10.8.0.$o"
    break
  fi
done
[ -n "$IP" ] || { echo "No IPs left in 10.8.0.0/24"; exit 1; }

PRIV="$(wg genkey)"
PUB="$(echo "$PRIV" | wg pubkey)"

CONF="$DIR/$FINAL.conf"

cat > "$CONF" <<WGCLIENT
[Interface]
PrivateKey = $PRIV
Address = $IP/32

[Peer]
PublicKey = $SERVER_PUB
Endpoint = ${SERVER_IP:-YOUR_SERVER_PUBLIC_IP}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
WGCLIENT

chmod 600 "$CONF"

cat >> "$SERVER_CONF" <<WGPEER

[Peer]
# $FINAL
PublicKey = $PUB
AllowedIPs = $IP/32
WGPEER
chmod 600 "$SERVER_CONF"

printf '%s|%s|%s\n' "$IP" "$SLUG" "$FINAL" >> "$BASE/maps/client_map.db"
printf '%s|%s|%s\n' "$PUB" "$FINAL" "$IP" >> "$BASE/maps/peers.db"

fi

if wg show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(wg-quick strip wg0)
else
  systemctl restart wg-quick@wg0
fi

# Keep the Apple link for the final summary instead of burying it in setup output.
IKE_ROW="$(awk -F'|' -v n="$FINAL" -v s="$SLUG" '$2==s && $3==n{print; exit}' "$BASE/maps/ikev2_map.db")"
if [ -n "$IKE_ROW" ]; then
  [ -s "$DIR/$FINAL.mobileconfig" ] || { echo "Existing Apple profile is missing. Restore it from backup: $DIR/$FINAL.mobileconfig"; exit 1; }
  IFS='|' read -r _ _ _ _ PROFILE_SHORT <<< "$IKE_ROW"
  SERVER_ID="$(cat "$BASE/ikev2/server/server_id")"
  IKE_OUTPUT="$(printf '\nApple TV / IKEv2 profile:\n  http://%s:8080/%s\n' "$SERVER_ID" "$PROFILE_SHORT")"
elif IKE_OUTPUT="$(/usr/local/lib/wireguard-proxy/new-ikev2-profile "$SLUG" "$FINAL" "$DIR")"; then
  :
else
  status=$?
  printf '%s\n' "$IKE_OUTPUT" >&2
  echo "Apple profile creation failed (status $status)." >&2
  exit "$status"
fi
/usr/local/lib/wireguard-proxy/apply-routing

echo
echo "Client created: $FINAL"
echo "WireGuard config: $CONF"
echo
echo "WireGuard QR (scan in the WireGuard app):"
if [ "$DISPLAY" = "--batch" ]; then
  echo "  View QR later: helper > Manage > Show saved profiles"
elif command -v qrencode >/dev/null 2>&1; then
  # Half-height Unicode blocks keep the QR compact; retain its quiet border.
  if ! qrencode -t ANSIUTF8 -l L -m 4 < "$CONF"; then
    echo "QR unavailable. Import the saved WireGuard config instead." >&2
  fi
else
  echo "QR unavailable. Install it with: sudo apt-get install -y qrencode" >&2
fi

# Always leave the Apple TV link visible below the QR, even if QR rendering fails.
printf '%s\n' "$IKE_OUTPUT"
