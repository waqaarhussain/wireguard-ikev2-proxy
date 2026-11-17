#!/usr/bin/env bash
set -euo pipefail

BASE="/Wireguard"
EXITS_DB="$BASE/maps/exits.db"
EXITS_DIR="$BASE/exits"
CLIENT_DIR="$BASE/client"
SERVER_CONF="/etc/wireguard/wg0.conf"
SERVER_PUB="$(cat "$BASE/server/server_publickey")"
SERVER_IP="$(curl -4 -s https://api.ipify.org || true)"

mkdir -p "$CLIENT_DIR"

pick_exit() {
  {
    echo
    echo "Available exits:"
    awk -F'|' '{printf "%2d) %s\n", NR, $3}' "$EXITS_DB"
  } >&2
  read -r -p "Select exit number: " NUM
  awk -F'|' -v n="$NUM" 'NR==n{print $1; exit}' "$EXITS_DB"
}

SLUG="${1:-}"
if [ -z "${SLUG:-}" ]; then
  SLUG="$(pick_exit)"
fi
[ -n "${SLUG:-}" ] || { echo "Invalid exit selection"; exit 1; }

ENV_FILE="$EXITS_DIR/$SLUG.env"
[ -f "$ENV_FILE" ] || { echo "Exit not found"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

read -r -p "Client name: " RAW_NAME
RAW_NAME="$(echo "$RAW_NAME" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$RAW_NAME" ] || { echo "Client name cannot be empty."; exit 1; }

FINAL="${RAW_NAME} - [${TYPE_TAG} - ${LABEL}]"

DIR="$CLIENT_DIR/$FINAL"
N=2
while [ -e "$DIR" ]; do
  DIR="$CLIENT_DIR/${FINAL}-${N}"
  N=$((N+1))
done
FINAL="$(basename "$DIR")"

USED="$(awk -F'|' '{print $1}' "$BASE/maps/client_map.db" | grep -Eo '10\.8\.0\.[0-9]+' | awk -F. '{print $4}' | sort -n | uniq || true)"
IP=""
for o in $(seq 2 254); do
  if ! echo "$USED" | grep -qx "$o"; then
    IP="10.8.0.$o"
    break
  fi
done
[ -n "$IP" ] || { echo "No IPs left in 10.8.0.0/24"; exit 1; }

mkdir -p "$DIR"
chmod 700 "$DIR"

umask 077
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

if wg show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(wg-quick strip wg0)
else
  systemctl restart wg-quick@wg0
fi

# Keep the Apple link for the final summary instead of burying it in setup output.
if IKE_OUTPUT="$(/usr/local/lib/wireguard-proxy/new-ikev2-profile "$SLUG" "$FINAL" "$DIR")"; then
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
if command -v qrencode >/dev/null 2>&1; then
  # Half-height Unicode blocks keep the QR compact; retain its quiet border.
  if ! qrencode -t ANSIUTF8 -l L -m 4 < "$CONF"; then
    echo "QR unavailable. Import the saved WireGuard config instead." >&2
  fi
else
  echo "QR unavailable. Install it with: sudo apt-get install -y qrencode" >&2
fi

# Always leave the Apple TV link visible below the QR, even if QR rendering fails.
printf '%s\n' "$IKE_OUTPUT"
