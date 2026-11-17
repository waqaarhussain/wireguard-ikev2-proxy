#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run this installer as root: sudo bash install.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y wireguard wireguard-tools iptables iproute2 curl ca-certificates procps jq iptables-persistent python3 qrencode

TMPDIR="$(mktemp -d)"
cd "$TMPDIR"
API_JSON="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest)"
ASSET_URL="$(printf '%s' "$API_JSON" | jq -r '.assets[] | select(.name | test("linux-amd64.*tar.gz$")) | .browser_download_url' | head -n1)"
[ -n "$ASSET_URL" ] || { echo "Could not find sing-box release"; exit 1; }
curl -fsSL "$ASSET_URL" -o sing-box.tar.gz
tar -xzf sing-box.tar.gz
install -m 755 "$(find . -type f -name sing-box | head -n1)" /usr/local/bin/sing-box
cd /
rm -rf "$TMPDIR"

cat >/etc/sysctl.d/99-wireguard.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYSCTL
sysctl --system >/dev/null

mkdir -p /Wireguard/{server,client,maps,proxies,exits}
mkdir -p /usr/local/lib/wireguard-proxy
chmod 700 /Wireguard
touch /Wireguard/maps/client_map.db
touch /Wireguard/maps/peers.db
touch /Wireguard/maps/exits.db

if [ ! -f /Wireguard/server/server_privatekey ]; then
  umask 077
  wg genkey | tee /Wireguard/server/server_privatekey | wg pubkey > /Wireguard/server/server_publickey
fi

MAIN_IFACE="$(ip route | awk '/default/ {print $5; exit}')"
SERVER_PRIVKEY="$(cat /Wireguard/server/server_privatekey)"

cat >/etc/wireguard/wg0.conf <<WGCONF
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = ${SERVER_PRIVKEY}
Table = off

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${MAIN_IFACE} -j MASQUERADE

PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${MAIN_IFACE} -j MASQUERADE
WGCONF

chmod 600 /etc/wireguard/wg0.conf
systemctl enable --now wg-quick@wg0

echo "BASE DONE"

cat >/usr/local/lib/wireguard-proxy/build-routes <<'BUILD'
#!/usr/bin/env bash
set -euo pipefail

EXITS_DIR="/Wireguard/exits"
EXITS_DB="/Wireguard/maps/exits.db"

mkdir -p "$EXITS_DIR"
: > "$EXITS_DB"

for f in "$EXITS_DIR"/*.env; do
  [ -f "$f" ] || continue

  unset ID SLUG LABEL TYPE TYPE_TAG SERVER PORT TUN TABLE ADDR AUTH_MODE USERNAME PASSWORD METHOD
  # shellcheck disable=SC1090
  source "$f"

  printf '%s|proxy|%s [%s]|%s|%s\n' "$SLUG" "$LABEL" "$TYPE_TAG" "$TUN" "$TABLE" >> "$EXITS_DB"
done
BUILD
chmod +x /usr/local/lib/wireguard-proxy/build-routes

cat >/usr/local/lib/wireguard-proxy/apply-routing <<'APPLY'
#!/usr/bin/env bash
set -euo pipefail

CLIENT_DB="/Wireguard/maps/client_map.db"
IKE_DB="/Wireguard/maps/ikev2_map.db"
EXITS_DB="/Wireguard/maps/exits.db"

for prio in $(ip rule | awk -F: '{gsub(/ /,"",$1); print $1}' | grep -E '^(100[1-9]|10[1-9][0-9]|1[1-9][0-9]{2})$' || true); do
  ip rule del priority "$prio" 2>/dev/null || true
done

ip rule add to 45.88.89.23 lookup main priority 50 2>/dev/null || true

apply_client_route() {
  local IP="$1"
  local SLUG="$2"
  [ -n "${IP:-}" ] || return 0

  LINE="$(awk -F'|' -v s="$SLUG" '$1==s{print; exit}' "$EXITS_DB")"
  [ -n "${LINE:-}" ] || return 0

  IFS='|' read -r _ TYPE LABEL TUN TABLE <<< "$LINE"

  systemctl start "singbox-exit@${SLUG}" 2>/dev/null || true

  for _ in $(seq 1 20); do
    ip link show "$TUN" >/dev/null 2>&1 && break
    sleep 0.25
  done

  ip route replace default dev "$TUN" table "$TABLE" 2>/dev/null || true
  ip rule add from "$IP" table "$TABLE" priority "$TABLE" 2>/dev/null || true
}

while IFS='|' read -r IP SLUG NAME; do
  [ -n "${IP:-}" ] || continue
  apply_client_route "$IP" "$SLUG"
done < "$CLIENT_DB"

if [ -f "$IKE_DB" ]; then
  while IFS='|' read -r IP SLUG NAME USERNAME; do
    [ -n "${IP:-}" ] || continue
    apply_client_route "$IP" "$SLUG"
  done < "$IKE_DB"
fi

ip route flush cache
APPLY
chmod +x /usr/local/lib/wireguard-proxy/apply-routing

cat >/etc/systemd/system/singbox-exit@.service <<'SVC'
[Unit]
Description=sing-box exit %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /Wireguard/proxies/%i.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload

echo "ROUTING DONE"
set -euo pipefail

cat >/usr/local/bin/add <<'ADD'
#!/usr/bin/env bash
set -euo pipefail

BASE="/Wireguard"
EXITS_DB="$BASE/maps/exits.db"
EXITS_DIR="$BASE/exits"
PROXY_DIR="$BASE/proxies"

mkdir -p "$EXITS_DIR" "$PROXY_DIR"

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//'
}

next_suffix_slug() {
  local base="$1"
  local slug="$base"
  local n=2
  while [ -e "$EXITS_DIR/$slug.env" ] || [ -e "$PROXY_DIR/$slug.json" ]; do
    slug="${base}-${n}"
    n=$((n+1))
  done
  printf '%s' "$slug"
}

next_id() {
  local max=0
  local f id
  for f in "$EXITS_DIR"/*.env; do
    [ -e "$f" ] || continue
    id="$(awk -F= '/^ID=/{print $2}' "$f" 2>/dev/null || true)"
    if [ -n "${id:-}" ] && [ "$id" -gt "$max" ]; then
      max="$id"
    fi
  done
  echo $((max+1))
}

write_proxy_json() {
  local env_file="$1"
  unset ID SLUG LABEL TYPE TYPE_TAG SERVER PORT TUN TABLE ADDR AUTH_MODE USERNAME PASSWORD METHOD
  # shellcheck disable=SC1090
  source "$env_file"

  if [ "$TYPE" = "http" ]; then
    jq -n \
      --arg tun "$TUN" \
      --arg addr "$ADDR" \
      --arg server "$SERVER" \
      --argjson port "$PORT" \
      --arg user "$USERNAME" \
      --arg pass "$PASSWORD" \
'{
  log: { level: "info" },
  inbounds: [
    {
      type: "tun",
      tag: "tun-in",
      interface_name: $tun,
      address: [$addr],
      mtu: 1500,
      auto_route: false,
      strict_route: true,
      auto_redirect: false,
      stack: "mixed"
    }
  ],
  outbounds: [
    {
      type: "http",
      tag: "proxy",
      server: $server,
      server_port: $port,
      username: $user,
      password: $pass
    },
    { type: "direct", tag: "direct" },
    { type: "block", tag: "block" }
  ],
  route: {
    auto_detect_interface: true,
    rules: [
      { ip_cidr: ["45.88.89.23/32"], outbound: "direct" }
    ],
    final: "proxy"
  }
}' > "$PROXY_DIR/$SLUG.json"
  elif [ "$TYPE" = "socks5" ]; then
    if [ "${AUTH_MODE:-ip}" = "auth" ]; then
      jq -n \
        --arg tun "$TUN" \
        --arg addr "$ADDR" \
        --arg server "$SERVER" \
        --argjson port "$PORT" \
        --arg user "$USERNAME" \
        --arg pass "$PASSWORD" \
'{
  log: { level: "info" },
  inbounds: [
    {
      type: "tun",
      tag: "tun-in",
      interface_name: $tun,
      address: [$addr],
      mtu: 1500,
      auto_route: false,
      strict_route: true,
      auto_redirect: false,
      stack: "mixed"
    }
  ],
  outbounds: [
    {
      type: "socks",
      tag: "proxy",
      server: $server,
      server_port: $port,
      username: $user,
      password: $pass
    },
    { type: "direct", tag: "direct" },
    { type: "block", tag: "block" }
  ],
  route: {
    auto_detect_interface: true,
    rules: [
      { ip_cidr: ["45.88.89.23/32"], outbound: "direct" }
    ],
    final: "proxy"
  }
}' > "$PROXY_DIR/$SLUG.json"
    else
      jq -n \
        --arg tun "$TUN" \
        --arg addr "$ADDR" \
        --arg server "$SERVER" \
        --argjson port "$PORT" \
'{
  log: { level: "info" },
  inbounds: [
    {
      type: "tun",
      tag: "tun-in",
      interface_name: $tun,
      address: [$addr],
      mtu: 1500,
      auto_route: false,
      strict_route: true,
      auto_redirect: false,
      stack: "mixed"
    }
  ],
  outbounds: [
    {
      type: "socks",
      tag: "proxy",
      server: $server,
      server_port: $port
    },
    { type: "direct", tag: "direct" },
    { type: "block", tag: "block" }
  ],
  route: {
    auto_detect_interface: true,
    rules: [
      { ip_cidr: ["45.88.89.23/32"], outbound: "direct" }
    ],
    final: "proxy"
  }
}' > "$PROXY_DIR/$SLUG.json"
    fi
  else
    jq -n \
      --arg tun "$TUN" \
      --arg addr "$ADDR" \
      --arg server "$SERVER" \
      --argjson port "$PORT" \
      --arg method "$METHOD" \
      --arg pass "$PASSWORD" \
'{
  log: { level: "info" },
  inbounds: [
    {
      type: "tun",
      tag: "tun-in",
      interface_name: $tun,
      address: [$addr],
      mtu: 1500,
      auto_route: false,
      strict_route: true,
      auto_redirect: false,
      stack: "mixed"
    }
  ],
  outbounds: [
    {
      type: "shadowsocks",
      tag: "proxy",
      server: $server,
      server_port: $port,
      method: $method,
      password: $pass
    },
    { type: "direct", tag: "direct" },
    { type: "block", tag: "block" }
  ],
  route: {
    auto_detect_interface: true,
    rules: [
      { ip_cidr: ["45.88.89.23/32"], outbound: "direct" }
    ],
    final: "proxy"
  }
}' > "$PROXY_DIR/$SLUG.json"
  fi
}

echo
echo "1) HTTP"
echo "2) SOCKS5"
echo "3) Shadowsocks"
read -r -p "Choice: " TYPE

case "$TYPE" in
  1) TYPE_NAME="http"; TYPE_TAG="HTTP" ;;
  2) TYPE_NAME="socks5"; TYPE_TAG="S5" ;;
  3) TYPE_NAME="shadowsocks"; TYPE_TAG="SS" ;;
  *) echo "Invalid choice"; exit 1 ;;
esac

read -r -p "Country label: " LABEL
[ -n "${LABEL:-}" ] || { echo "Country label cannot be empty"; exit 1; }

BASE_SLUG="$(slugify "$LABEL")"
[ -n "${BASE_SLUG:-}" ] || BASE_SLUG="exit"
SLUG="$(next_suffix_slug "$BASE_SLUG")"

read -r -p "Address: " SERVER
read -r -p "Port: " PORT

AUTH_MODE=""
USERNAME=""
PASSWORD=""
METHOD=""

if [ "$TYPE_NAME" = "http" ]; then
  read -r -p "Username: " USERNAME
  read -r -p "Password: " PASSWORD
fi

if [ "$TYPE_NAME" = "socks5" ]; then
  echo
  echo "1) IP whitelist"
  echo "2) Username and password"
  read -r -p "Choice: " SOCK_AUTH
  case "$SOCK_AUTH" in
    1) AUTH_MODE="ip" ;;
    2)
      AUTH_MODE="auth"
      read -r -p "Username: " USERNAME
      read -r -p "Password: " PASSWORD
      ;;
    *) echo "Invalid choice"; exit 1 ;;
  esac
fi

if [ "$TYPE_NAME" = "shadowsocks" ]; then
  METHODS=(
    "rc4"
    "rc4-md5"
    "rc4-md5-6"
    "salsa20"
    "chacha20"
    "chacha20-ietf"
    "aes-256-cfb"
    "aes-192-cfb"
    "aes-128-cfb"
    "aes-256-cfb1"
    "aes-192-cfb1"
    "aes-128-cfb1"
    "aes-256-cfb8"
    "aes-192-cfb8"
    "aes-128-cfb8"
    "aes-256-ctr"
    "aes-192-ctr"
    "aes-128-ctr"
    "bf-cfb"
    "camellia-128-cfb"
    "camellia-192-cfb"
    "camellia-256-cfb"
    "cast5-cfb"
    "des-cfb"
    "idea-cfb"
    "rc2-cfb"
    "seed-cfb"
    "aes-256-gcm"
    "aes-192-gcm"
    "aes-128-gcm"
    "chacha20-ietf-poly1305"
    "chacha20-poly1305"
    "xchacha20-ietf-poly1305"
    "2022-blake3-aes-256-gcm"
    "2022-blake3-aes-128-gcm"
    "2022-blake3-chacha20-poly1305"
  )
  echo
  echo "Select method:"
  for i in "${!METHODS[@]}"; do
    printf "%2d) %s\n" "$((i+1))" "${METHODS[$i]}"
  done
  read -r -p "Method number: " MNUM
  METHOD="${METHODS[$((MNUM-1))]:-}"
  [ -n "${METHOD:-}" ] || { echo "Invalid method"; exit 1; }
  read -r -p "Password: " PASSWORD
fi

echo
echo "Confirm exit:"
echo "  Country: $LABEL"
echo "  Type:    $TYPE_TAG"
echo "  Address: $SERVER"
echo "  Port:    $PORT"
if [ "$TYPE_NAME" = "http" ]; then
  echo "  Username: $USERNAME"
  echo "  Password: $PASSWORD"
fi
if [ "$TYPE_NAME" = "socks5" ]; then
  echo "  Auth: ${AUTH_MODE:-ip}"
  [ "${AUTH_MODE:-}" = "auth" ] && echo "  Username: $USERNAME"
  [ "${AUTH_MODE:-}" = "auth" ] && echo "  Password: $PASSWORD"
fi
if [ "$TYPE_NAME" = "shadowsocks" ]; then
  echo "  Method: $METHOD"
  echo "  Password: $PASSWORD"
fi

read -r -p "Proceed? [y/N]: " OK
case "${OK:-N}" in
  y|Y) ;;
  *) echo "Cancelled"; exit 0 ;;
esac

ID="$(next_id)"
TABLE=$((1000 + ID))
TUN="sb${ID}"
OCTET=$((ID % 250 + 1))
ADDR="172.30.${OCTET}.1/30"

cat >"$EXITS_DIR/$SLUG.env" <<EOF2
ID=$(printf '%q' "$ID")
SLUG=$(printf '%q' "$SLUG")
LABEL=$(printf '%q' "$LABEL")
TYPE=$(printf '%q' "$TYPE_NAME")
TYPE_TAG=$(printf '%q' "$TYPE_TAG")
SERVER=$(printf '%q' "$SERVER")
PORT=$(printf '%q' "$PORT")
TUN=$(printf '%q' "$TUN")
TABLE=$(printf '%q' "$TABLE")
ADDR=$(printf '%q' "$ADDR")
AUTH_MODE=$(printf '%q' "${AUTH_MODE:-}")
USERNAME=$(printf '%q' "${USERNAME:-}")
PASSWORD=$(printf '%q' "${PASSWORD:-}")
METHOD=$(printf '%q' "${METHOD:-}")
EOF2
chmod 600 "$EXITS_DIR/$SLUG.env"

write_proxy_json "$EXITS_DIR/$SLUG.env"
/usr/local/bin/sing-box check -c "$PROXY_DIR/$SLUG.json"

systemctl enable "singbox-exit@${SLUG}" >/dev/null 2>&1 || true
/usr/local/lib/wireguard-proxy/build-routes

echo
read -r -p "Start/restart this exit now? [y/N]: " RESTART
case "${RESTART:-N}" in
  y|Y)
    systemctl restart "singbox-exit@${SLUG}" || systemctl start "singbox-exit@${SLUG}"
    ;;
esac

echo
echo "Exit saved: ${LABEL} [${TYPE_TAG}]"
echo "Slug: $SLUG"
# Every saved client gets its own pair of profiles for this new exit.
if python3 /usr/local/lib/wireguard-proxy/client-manager sync-exit "$SLUG"; then
  :
else
  echo "The proxy is saved. Retry unfinished profiles through Manage > Sync missing profiles." >&2
  exit 1
fi
ADD
chmod +x /usr/local/bin/add

cat >/usr/local/bin/new <<'NEWCLIENT'
#!/usr/bin/env bash
set -euo pipefail
[ -f /usr/local/lib/wireguard-proxy/client-manager ] || {
  echo "Client tools need updating. Run the update-helpers.sh command from the project README." >&2
  exit 1
}
exec python3 /usr/local/lib/wireguard-proxy/client-manager new "$@"
NEWCLIENT
chmod +x /usr/local/bin/new

cat >/usr/local/lib/wireguard-proxy/create-profile <<'CREATEPROFILE'
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
CREATEPROFILE
chmod +x /usr/local/lib/wireguard-proxy/create-profile

cat >/usr/local/lib/wireguard-proxy/client-manager <<'CLIENTMANAGER'
#!/usr/bin/env python3
"""Saved clients with one independent WireGuard/IKEv2 profile per proxy exit."""
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


class ClientManager:
    def __init__(self, base=Path('/Wireguard'), lib=Path('/usr/local/lib/wireguard-proxy'),
                 wg_conf=Path('/etc/wireguard/wg0.conf'),
                 ike_dir=Path('/etc/ipsec.d/clients'),
                 public=Path('/var/lib/wireguard-proxy-public')):
        self.base, self.lib, self.wg_conf = Path(base), Path(lib), Path(wg_conf)
        self.ike_dir, self.public = Path(ike_dir), Path(public)
        self.maps = self.base / 'maps'
        self.registry = self.maps / 'clients.json'
        self.names = []

    def rows(self, filename):
        path = self.maps / filename
        return [line.split('|') for line in path.read_text().splitlines() if line] if path.exists() else []

    @staticmethod
    def safe_component(name):
        return isinstance(name, str) and bool(name) and name not in ('.', '..') and not any(c in name for c in '/\\|\n\r\0')

    @staticmethod
    def validate_name(name):
        if not name or len(name) > 64 or not name.isprintable() or any(c in name for c in '/\\|'):
            raise ValueError('Use 1 to 64 printable characters, without slash, backslash or |, for the client name.')
        return name

    def canonical(self, name):
        return next((n for n in self.names if n.casefold() == name.casefold()), name)

    def save(self):
        temporary = self.registry.with_suffix('.tmp')
        temporary.write_text(json.dumps({'version': 1, 'clients': self.names}, indent=2) + '\n')
        temporary.chmod(0o600)
        temporary.replace(self.registry)

    def load(self):
        if self.registry.exists():
            data = json.loads(self.registry.read_text())
            if not isinstance(data, dict) or data.get('version') != 1 or not isinstance(data.get('clients'), list):
                raise ValueError('Unrecognized client registry. Restore clients.json from backup.')
            self.names = data['clients']
            if not all(isinstance(n, str) and n for n in self.names):
                raise ValueError('Invalid client registry. Restore clients.json from backup.')
        for profile in self.profiles():
            name = self.canonical(profile['client'])
            if name not in self.names:
                self.names.append(name)
        self.save()

    def exits(self):
        return {r[0]: r[2] for r in self.rows('exits.db')
                if len(r) >= 3 and self.safe_component(r[0])
                and (self.base / 'exits' / (r[0] + '.env')).is_file()}

    def profiles(self):
        # Legacy map names are imported in place, without regenerating keys or files.
        found = {}
        for row in self.rows('client_map.db'):
            if len(row) < 3 or not self.safe_component(row[2]):
                continue
            final = row[2]
            match = re.fullmatch(r'(.*) - \[.*\](?:-\d+)?', final)
            name = match[1] if match else final
            found[final] = {'final': final, 'client': name, 'exit': row[1]}
        folder = self.base / 'client'
        if folder.exists():
            for meta in sorted(folder.glob('*/.client-info.json')):
                if meta.parent.is_symlink() or not self.safe_component(meta.parent.name):
                    continue
                info = json.loads(meta.read_text())
                if not isinstance(info, dict) or not isinstance(info.get('client'), str) or not self.safe_component(info.get('exit', '')):
                    raise ValueError('Invalid profile metadata: ' + str(meta))
                found[meta.parent.name] = dict(final=meta.parent.name, client=info['client'], exit=info['exit'])
        for profile in found.values():
            profile['client'] = self.canonical(profile['client'])
        return list(found.values())

    def directory(self, profile):
        return self.base / 'client' / profile['final']

    def ike_row(self, profile):
        return next((r for r in self.rows('ikev2_map.db') if len(r) >= 5
                     and r[1] == profile['exit'] and r[2] == profile['final']), None)

    def ready(self, profile):
        final = profile['final']
        directory = self.directory(profile)
        files = (directory / (final + '.conf'), directory / (final + '.mobileconfig'))
        return (all(p.is_file() and p.stat().st_size for p in files)
                and any(len(r) >= 3 and r[1:3] == [profile['exit'], final] for r in self.rows('client_map.db'))
                and any(len(r) >= 3 and r[1] == final for r in self.rows('peers.db'))
                and self.ike_row(profile) is not None)

    def free_slots(self, filename, subnet):
        used = set()
        network = ipaddress.ip_network(subnet)
        for row in self.rows(filename):
            try:
                address = ipaddress.ip_address(row[0])
            except ValueError:
                continue
            if address in network and 2 <= int(str(address).split('.')[-1]) <= 254:
                used.add(address)
        return 253 - len(used)

    def sync(self, names, slugs, batch=True):
        available = self.exits()
        for slug in slugs:
            if slug not in available:
                raise ValueError('Proxy exit not found: ' + slug)
        if not names:
            print('No saved clients yet. Use helper > Create a client; future proxies will include it.')
            return 0
        if not slugs:
            print('No proxy exits yet. Clients are saved; adding a proxy will generate their profiles.')
            return 0
        current = self.profiles()
        plan, skipped = [], 0
        for name in names:
            self.validate_name(name)
            for slug in slugs:
                matches = [p for p in current if p['client'] == name and p['exit'] == slug]
                if any(self.ready(p) for p in matches):
                    skipped += 1
                else:
                    plan.append((name, slug, matches[0] if matches else None))
        # Count pending WireGuard and IKEv2 allocations separately before starting a bulk sync.
        for filename, subnet, kind in (('client_map.db', '10.8.0.0/24', 'WireGuard'),
                                        ('ikev2_map.db', '10.9.0.0/24', 'IKEv2')):
            rows = self.rows(filename)
            needed = sum(1 for _, slug, p in plan if p is None or not any(
                len(r) >= 3 and r[1:3] == [slug, p['final']] for r in rows))
            free = self.free_slots(filename, subnet)
            if needed > free:
                raise ValueError(f'{kind} address capacity: need {needed} new addresses, only {free} free.')
        failed = 0
        for name, slug, profile in plan:
            print(f'\nCreating: {name} / {available[slug]}', flush=True)
            command = [str(self.lib / 'create-profile'), slug, name,
                       profile['final'] if profile else '', '--batch' if batch else '']
            result = subprocess.run(command)
            self.load()
            complete = any(p['client'] == name and p['exit'] == slug and self.ready(p) for p in self.profiles())
            if result.returncode or not complete:
                failed += 1
                print(f'Failed: {name} / {available[slug]}. Run Manage > Sync missing profiles to retry.', file=sys.stderr)
        route_failed = False
        if any(self.ready(p) for p in self.profiles()):
            route_failed = subprocess.run([str(self.lib / 'apply-routing')]).returncode != 0
            if route_failed:
                print('Route application failed. Run Manage > Sync missing profiles to retry.', file=sys.stderr)
        print(f'\nProfiles: {len(plan) - failed} created/recovered, {skipped} already present, {failed} failed.')
        if not batch and not plan and current:
            matches = [p for p in current if p['client'] in names and p['exit'] in slugs and self.ready(p)]
            if matches:
                self.show_profile(matches[0])
        if batch:
            print('View a QR and Apple TV link: helper > Manage > Show saved profiles.')
        return 1 if failed or route_failed else 0

    @staticmethod
    def choose(options, prompt):
        for i, text in enumerate(options, 1):
            print(f'  [{i}] {text}')
        value = input(prompt).strip()
        if not value.isdecimal() or not 1 <= int(value) <= len(options):
            raise ValueError('Invalid selection.')
        return int(value) - 1

    def new(self, slug=None):
        if slug and slug not in self.exits():
            raise ValueError('Proxy exit not found: ' + slug)
        name = self.validate_name(input('Client name: ').strip())
        name = self.canonical(name)
        if name not in self.names:
            self.names.append(name)
            self.save()
        exits = self.exits()
        if not exits:
            print('Client saved: ' + name)
            return self.sync([name], [])
        if slug:
            return self.sync([name], [slug], batch=False)
        print('\nProxy exits:\n  [0] All proxies (default)')
        for i, label in enumerate(exits.values(), 1):
            print(f'  [{i}] {label}')
        choice = input('Select proxy [0]: ').strip() or '0'
        if not choice.isdecimal() or not 0 <= int(choice) <= len(exits):
            raise ValueError('Invalid proxy selection. Client is saved; retry new with the same name.')
        selected = list(exits) if int(choice) == 0 else [list(exits)[int(choice) - 1]]
        return self.sync([name], selected, batch=len(selected) > 1)

    def show_profile(self, profile):
        final = profile['final']
        conf = self.directory(profile) / (final + '.conf')
        if not conf.is_file():
            raise ValueError('WireGuard config missing: ' + str(conf))
        print('\n' + final + '\nWireGuard config: ' + str(conf), flush=True)
        if shutil.which('qrencode'):
            with conf.open('rb') as stream:
                if subprocess.run(['qrencode', '-t', 'ANSIUTF8', '-l', 'L', '-m', '4'], stdin=stream).returncode:
                    print('QR unavailable. Import the saved config instead.')
        else:
            print('QR unavailable. Install it with: sudo apt-get install -y qrencode')
        row = self.ike_row(profile)
        mobile = self.directory(profile) / (final + '.mobileconfig')
        if row and self.safe_component(row[4]) and mobile.is_file():
            self.public.mkdir(parents=True, exist_ok=True)
            self.public.chmod(0o755)
            published = self.public / row[4]
            if not published.exists():
                shutil.copyfile(mobile, published)
                published.chmod(0o644)
            subprocess.run(['systemctl', 'start', 'wg-http'], check=True)
            server = (self.base / 'ikev2/server/server_id').read_text().strip()
            print(f'\nApple TV / IKEv2 profile:\n  http://{server}:8080/{row[4]}')
        else:
            print('Apple profile incomplete. Run Manage > Sync missing profiles.')

    def show(self):
        if not self.names:
            print('No saved clients.')
            return 0
        name = self.names[self.choose(self.names, 'Select client: ')]
        profiles = [p for p in self.profiles() if p['client'] == name]
        if not profiles:
            print('No profiles for this client yet. Add a proxy or sync missing profiles.')
            return 0
        profile = profiles[self.choose([p['final'] for p in profiles], 'Select profile: ')]
        self.show_profile(profile)
        return 0

    def remove(self):
        if not self.names:
            print('No saved clients.')
            return 0
        name = self.names[self.choose(self.names, 'Select client to remove: ')]
        profiles = [p for p in self.profiles() if p['client'] == name]
        if input(f'Remove {name} and all {len(profiles)} profiles? [y/N]: ').lower() != 'y':
            print('Cancelled.')
            return 0
        finals = {p['final'] for p in profiles}
        peers = self.rows('peers.db')
        keys = {r[0] for r in peers if len(r) >= 3 and r[1] in finals}
        text = self.wg_conf.read_text()
        sections = re.split(r'(?=^\[Peer\]\s*$)', text, flags=re.M)
        kept = []
        for section in sections:
            pub = re.search(r'^PublicKey\s*=\s*(\S+)\s*$', section, re.M)
            label = re.search(r'^# (.+)$', section, re.M)
            belongs = (pub and pub[1] in keys) or (label and label[1] in finals)
            if not (section.startswith('[Peer]') and belongs):
                kept.append(section)
        self.wg_conf.write_text(''.join(kept))
        self.wg_conf.chmod(0o600)
        ike_rows = [r for r in self.rows('ikev2_map.db') if len(r) >= 5 and r[2] in finals]
        for filename, index in (('client_map.db', 2), ('peers.db', 1), ('ikev2_map.db', 2)):
            rows = [r for r in self.rows(filename) if len(r) <= index or r[index] not in finals]
            path = self.maps / filename
            path.write_text(''.join('|'.join(r) + '\n' for r in rows))
            path.chmod(0o600)
        for row in ike_rows:
            if self.safe_component(row[3]):
                (self.ike_dir / (row[3] + '.conf')).unlink(missing_ok=True)
            if self.safe_component(row[4]):
                (self.public / row[4]).unlink(missing_ok=True)
        for profile in profiles:
            directory = self.directory(profile)
            if directory.exists() and not directory.is_symlink():
                shutil.rmtree(directory)
        self.names.remove(name)
        self.save()
        # Apply the reduced peer list without disconnecting unrelated WireGuard clients.
        stripped = subprocess.run(['wg-quick', 'strip', 'wg0'], capture_output=True, check=True)
        import tempfile
        with tempfile.NamedTemporaryFile() as configuration:
            configuration.write(stripped.stdout)
            configuration.flush()
            subprocess.run(['wg', 'syncconf', 'wg0', configuration.name], check=True)
        result = subprocess.run(['systemctl', 'restart', 'strongswan-starter'])
        if result.returncode:
            subprocess.run(['systemctl', 'restart', 'strongswan'], check=True)
        subprocess.run([str(self.lib / 'apply-routing')], check=True)
        print('Removed client and all profiles: ' + name)
        return 0


def main():
    if os.geteuid() != 0:
        sys.exit('Run this command through helper or with sudo.')
    os.umask(0o077)
    manager = ClientManager()
    manager.maps.mkdir(parents=True, exist_ok=True)
    with (manager.maps / 'client-manager.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manager.load()
        command = sys.argv[1] if len(sys.argv) > 1 else 'new'
        if command == 'new':
            return manager.new(sys.argv[2] if len(sys.argv) > 2 else None)
        if command == 'sync-exit' and len(sys.argv) == 3:
            return manager.sync(manager.names[:], [sys.argv[2]])
        if command == 'sync':
            return manager.sync(manager.names[:], list(manager.exits()))
        if command == 'show':
            return manager.show()
        if command == 'remove':
            return manager.remove()
        if command == 'migrate':
            print(f'Imported {len(manager.names)} saved clients. Existing profile files are unchanged.')
            return 0
        raise ValueError('Unknown client-manager command.')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
    except (EOFError, KeyboardInterrupt):
        sys.exit('\nCancelled.')
CLIENTMANAGER
chmod +x /usr/local/lib/wireguard-proxy/client-manager

cat >/usr/local/lib/wireguard-proxy/edit-proxy <<'EDIT'
#!/usr/bin/env bash
set -euo pipefail

BASE="/Wireguard"
EXITS_DIR="$BASE/exits"
PROXY_DIR="$BASE/proxies"

write_proxy_json() {
  local env_file="$1"
  unset ID SLUG LABEL TYPE TYPE_TAG SERVER PORT TUN TABLE ADDR AUTH_MODE USERNAME PASSWORD METHOD
  # shellcheck disable=SC1090
  source "$env_file"

  if [ "$TYPE" = "http" ]; then
    jq -n \
      --arg tun "$TUN" \
      --arg addr "$ADDR" \
      --arg server "$SERVER" \
      --argjson port "$PORT" \
      --arg user "$USERNAME" \
      --arg pass "$PASSWORD" \
'{
  log: { level: "info" },
  inbounds: [
    {
      type: "tun",
      tag: "tun-in",
      interface_name: $tun,
      address: [$addr],
      mtu: 1500,
      auto_route: false,
      strict_route: true,
      auto_redirect: false,
      stack: "mixed"
    }
  ],
  outbounds: [
    {
      type: "http",
      tag: "proxy",
      server: $server,
      server_port: $port,
      username: $user,
      password: $pass
    },
    { type: "direct", tag: "direct" },
    { type: "block", tag: "block" }
  ],
  route: {
    auto_detect_interface: true,
    rules: [
      { ip_cidr: ["45.88.89.23/32"], outbound: "direct" }
    ],
    final: "proxy"
  }
}' > "$PROXY_DIR/$SLUG.json"
  elif [ "$TYPE" = "socks5" ]; then
    if [ "${AUTH_MODE:-ip}" = "auth" ]; then
      jq -n \
        --arg tun "$TUN" \
        --arg addr "$ADDR" \
        --arg server "$SERVER" \
        --argjson port "$PORT" \
        --arg user "$USERNAME" \
        --arg pass "$PASSWORD" \
'{
  log: { level: "info" },
  inbounds: [
    {
      type: "tun",
      tag: "tun-in",
      interface_name: $tun,
      address: [$addr],
      mtu: 1500,
      auto_route: false,
      strict_route: true,
      auto_redirect: false,
      stack: "mixed"
    }
  ],
  outbounds: [
    {
      type: "socks",
      tag: "proxy",
      server: $server,
      server_port: $port,
      username: $user,
      password: $pass
    },
    { type: "direct", tag: "direct" },
    { type: "block", tag: "block" }
  ],
  route: {
    auto_detect_interface: true,
    rules: [
      { ip_cidr: ["45.88.89.23/32"], outbound: "direct" }
    ],
    final: "proxy"
  }
}' > "$PROXY_DIR/$SLUG.json"
    else
      jq -n \
        --arg tun "$TUN" \
        --arg addr "$ADDR" \
        --arg server "$SERVER" \
        --argjson port "$PORT" \
'{
  log: { level: "info" },
  inbounds: [
    {
      type: "tun",
      tag: "tun-in",
      interface_name: $tun,
      address: [$addr],
      mtu: 1500,
      auto_route: false,
      strict_route: true,
      auto_redirect: false,
      stack: "mixed"
    }
  ],
  outbounds: [
    {
      type: "socks",
      tag: "proxy",
      server: $server,
      server_port: $port
    },
    { type: "direct", tag: "direct" },
    { type: "block", tag: "block" }
  ],
  route: {
    auto_detect_interface: true,
    rules: [
      { ip_cidr: ["45.88.89.23/32"], outbound: "direct" }
    ],
    final: "proxy"
  }
}' > "$PROXY_DIR/$SLUG.json"
    fi
  else
    jq -n \
      --arg tun "$TUN" \
      --arg addr "$ADDR" \
      --arg server "$SERVER" \
      --argjson port "$PORT" \
      --arg method "$METHOD" \
      --arg pass "$PASSWORD" \
'{
  log: { level: "info" },
  inbounds: [
    {
      type: "tun",
      tag: "tun-in",
      interface_name: $tun,
      address: [$addr],
      mtu: 1500,
      auto_route: false,
      strict_route: true,
      auto_redirect: false,
      stack: "mixed"
    }
  ],
  outbounds: [
    {
      type: "shadowsocks",
      tag: "proxy",
      server: $server,
      server_port: $port,
      method: $method,
      password: $pass
    },
    { type: "direct", tag: "direct" },
    { type: "block", tag: "block" }
  ],
  route: {
    auto_detect_interface: true,
    rules: [
      { ip_cidr: ["45.88.89.23/32"], outbound: "direct" }
    ],
    final: "proxy"
  }
}' > "$PROXY_DIR/$SLUG.json"
  fi
}

mapfile -t FILES < <(find "$EXITS_DIR" -maxdepth 1 -type f -name '*.env' | sort)
[ "${#FILES[@]}" -gt 0 ] || { echo "No proxies found."; exit 1; }

echo
echo "Proxies:"
for i in "${!FILES[@]}"; do
  unset LABEL TYPE_TAG
  # shellcheck disable=SC1090
  source "${FILES[$i]}"
  printf "  [%d] %s [%s]\n" "$((i+1))" "$LABEL" "$TYPE_TAG"
done
echo
read -r -p "Select proxy number: " choice
[[ "$choice" =~ ^[0-9]+$ ]] || { echo "Not a number."; exit 1; }
(( choice >= 1 && choice <= ${#FILES[@]} )) || { echo "Out of range."; exit 1; }

ENV_FILE="${FILES[$((choice-1))]}"

unset ID SLUG LABEL TYPE TYPE_TAG SERVER PORT TUN TABLE ADDR AUTH_MODE USERNAME PASSWORD METHOD
# shellcheck disable=SC1090
source "$ENV_FILE"

echo
echo "1) Address"
echo "2) Port"
echo "3) Label"
echo "4) Username"
echo "5) Password"
echo "6) Auth mode"
echo "7) Method"
echo
read -r -p "What do you want to edit? " field

case "$field" in
  1)
    read -r -p "New address: " SERVER
    ;;
  2)
    read -r -p "New port: " PORT
    ;;
  3)
    read -r -p "New label: " LABEL
    ;;
  4)
    read -r -p "New username: " USERNAME
    ;;
  5)
    read -r -p "New password: " PASSWORD
    ;;
  6)
    if [ "$TYPE" = "socks5" ]; then
      echo "1) IP whitelist"
      echo "2) Username and password"
      read -r -p "Choice: " am
      case "$am" in
        1) AUTH_MODE="ip"; USERNAME=""; PASSWORD="" ;;
        2) AUTH_MODE="auth" ;;
        *) echo "Invalid choice"; exit 1 ;;
      esac
    else
      echo "Auth mode only applies to SOCKS5."
      exit 1
    fi
    ;;
  7)
    if [ "$TYPE" = "shadowsocks" ]; then
      read -r -p "New method: " METHOD
    else
      echo "Method only applies to Shadowsocks."
      exit 1
    fi
    ;;
  *)
    echo "Invalid choice"
    exit 1
    ;;
esac

cat >"$ENV_FILE" <<EOF2
ID=$(printf '%q' "$ID")
SLUG=$(printf '%q' "$SLUG")
LABEL=$(printf '%q' "$LABEL")
TYPE=$(printf '%q' "$TYPE")
TYPE_TAG=$(printf '%q' "$TYPE_TAG")
SERVER=$(printf '%q' "$SERVER")
PORT=$(printf '%q' "$PORT")
TUN=$(printf '%q' "$TUN")
TABLE=$(printf '%q' "$TABLE")
ADDR=$(printf '%q' "$ADDR")
AUTH_MODE=$(printf '%q' "${AUTH_MODE:-}")
USERNAME=$(printf '%q' "${USERNAME:-}")
PASSWORD=$(printf '%q' "${PASSWORD:-}")
METHOD=$(printf '%q' "${METHOD:-}")
EOF2
chmod 600 "$ENV_FILE"

write_proxy_json "$ENV_FILE"
/usr/local/bin/sing-box check -c "$PROXY_DIR/$SLUG.json"
/usr/local/lib/wireguard-proxy/build-routes
systemctl restart "singbox-exit@${SLUG}" || systemctl start "singbox-exit@${SLUG}"

echo "Updated: $LABEL [$TYPE_TAG]"
EDIT
chmod +x /usr/local/lib/wireguard-proxy/edit-proxy

cat >/usr/local/lib/wireguard-proxy/remove-client <<'REMOVE'
#!/usr/bin/env bash
set -euo pipefail
exec python3 /usr/local/lib/wireguard-proxy/client-manager remove
REMOVE
chmod +x /usr/local/lib/wireguard-proxy/remove-client

cat >/usr/local/lib/wireguard-proxy/check-clients <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail

PEERS_DB="/Wireguard/maps/peers.db"
NOW="$(date +%s)"
ACTIVE_WINDOW=60

echo
echo "All clients:"
if [ -s "$PEERS_DB" ]; then
  while IFS='|' read -r PUB NAME IP; do
    [ -n "${PUB:-}" ] || continue
    LAST="$(wg show wg0 latest-handshakes 2>/dev/null | awk -v p="$PUB" '$1==p{print $2}')"
    DOT=""
    if [ -n "${LAST:-}" ] && [ "$LAST" != "0" ] && [ $((NOW - LAST)) -le "$ACTIVE_WINDOW" ]; then
      DOT=" 🟢"
    fi
    printf "%s%s\n" "$NAME" "$DOT"
  done < "$PEERS_DB"
else
  echo "No clients saved."
fi
echo
CHECK
chmod +x /usr/local/lib/wireguard-proxy/check-clients

echo "HELPERS DONE"

iptables -C INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport 51820 -j ACCEPT
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
netfilter-persistent save >/dev/null 2>&1 || true

/usr/local/lib/wireguard-proxy/build-routes
/usr/local/lib/wireguard-proxy/apply-routing || true

cat >/usr/local/bin/bench <<'BENCH'
#!/usr/bin/env bash
set -euo pipefail

BASE="/Wireguard"
EXITS_DB="$BASE/maps/exits.db"
TMPDIR="$(mktemp -d)"
RESULTS="$TMPDIR/results.tsv"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

[ -s "$EXITS_DB" ] || { echo "No exits found in $EXITS_DB"; exit 1; }

echo
echo "1) All proxy exits"
echo "2) All HTTP exits"
echo "3) All SOCKS5 exits"
echo "4) All Shadowsocks exits"
read -r -p "Choice: " CHOICE

case "${CHOICE:-1}" in
  1) FILTER_MODE="ALL" ;;
  2) FILTER_MODE="HTTP" ;;
  3) FILTER_MODE="S5" ;;
  4) FILTER_MODE="SS" ;;
  *) echo "Invalid choice"; exit 1 ;;
esac

matches_filter() {
  local pretty="$1"
  case "$FILTER_MODE" in
    ALL) return 0 ;;
    HTTP) [[ "$pretty" == *"[HTTP]"* ]] ;;
    S5) [[ "$pretty" == *"[S5]"* ]] ;;
    SS) [[ "$pretty" == *"[SS]"* ]] ;;
    *) return 1 ;;
  esac
}

IPINFO_URL="https://ipinfo.io/json"
DOWNLOAD_URL="https://speed.cloudflare.com/__down?bytes=20000000"

STREAM_URLS=(
  "https://www.youtube.com/"
  "https://www.netflix.com/"
  "https://fast.com/"
  "https://www.apple.com/"
)

CURL_TIMEOUT=45

best_speed_name=""
best_speed_value="0"

best_latency_name=""
best_latency_connect="999999"
best_latency_ttfb="999999"

best_stream_name=""
best_stream_score="-1"

matched_count=0

while IFS='|' read -r SLUG KIND PRETTY TUN TABLE; do
  [ -n "${SLUG:-}" ] || continue
  matches_filter "$PRETTY" || continue
  matched_count=$((matched_count+1))

  systemctl restart "singbox-exit@${SLUG}" >/dev/null 2>&1 || systemctl start "singbox-exit@${SLUG}" >/dev/null 2>&1 || true

  ok=0
  for _ in $(seq 1 40); do
    if ip link show "$TUN" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 0.25
  done

  if [ "$ok" -ne 1 ]; then
    printf "%s\t-\t-\t-\t-\t999999\t999999\t0\t0\tTUN_DOWN\n" "$PRETTY" >> "$RESULTS"
    continue
  fi

  IP_JSON="$TMPDIR/${SLUG}_ipinfo.json"
  METRICS_OUT="$TMPDIR/${SLUG}_metrics.txt"
  BODY_OUT="$TMPDIR/${SLUG}_body.bin"

  if ! curl --interface "$TUN" \
      --silent --show-error --fail \
      --max-time "$CURL_TIMEOUT" \
      "$IPINFO_URL" >"$IP_JSON" 2>"$TMPDIR/${SLUG}_ip.err"; then
    printf "%s\t-\t-\t-\t-\t999999\t999999\t0\t0\tIPINFO_FAIL\n" "$PRETTY" >> "$RESULTS"
    continue
  fi

  EXIT_IP="$(jq -r '.ip // "-"' "$IP_JSON" 2>/dev/null || echo "-")"
  COUNTRY="$(jq -r '.country // "-"' "$IP_JSON" 2>/dev/null || echo "-")"
  CITY="$(jq -r '.city // "-"' "$IP_JSON" 2>/dev/null || echo "-")"
  ORG="$(jq -r '.org // "-"' "$IP_JSON" 2>/dev/null || echo "-")"

  if ! curl --interface "$TUN" \
      --silent --show-error --fail \
      --output "$BODY_OUT" \
      --max-time "$CURL_TIMEOUT" \
      --write-out '%{time_connect}\t%{time_starttransfer}\t%{time_total}\t%{size_download}\n' \
      "$DOWNLOAD_URL" >"$METRICS_OUT" 2>"$TMPDIR/${SLUG}_dl.err"; then
    printf "%s\t%s\t%s\t%s\t%s\t999999\t999999\t0\t0\tDL_FAIL\n" \
      "$PRETTY" "$EXIT_IP" "$COUNTRY" "$CITY" "$ORG" >> "$RESULTS"
    continue
  fi

  IFS=$'\t' read -r TIME_CONNECT TIME_TTFB TIME_TOTAL SIZE_DOWN < "$METRICS_OUT"

  CONNECT_MS="$(awk -v x="$TIME_CONNECT" 'BEGIN{printf "%.0f", x*1000}')"
  TTFB_MS="$(awk -v x="$TIME_TTFB" 'BEGIN{printf "%.0f", x*1000}')"
  MBPS="$(awk -v bytes="$SIZE_DOWN" -v secs="$TIME_TOTAL" 'BEGIN{ if (secs <= 0) {print "0.00"} else { printf "%.2f", (bytes*8/1000000)/secs } }')"

  stream_ok=0
  stream_ttfb_total=0

  for url in "${STREAM_URLS[@]}"; do
    probe="$TMPDIR/${SLUG}_probe.txt"
    if curl --interface "$TUN" \
        --silent --show-error \
        --location \
        --output /dev/null \
        --max-time 20 \
        --write-out '%{http_code}\t%{time_starttransfer}\n' \
        "$url" >"$probe" 2>/dev/null; then
      code="$(awk -F'\t' '{print $1}' "$probe")"
      sttfb="$(awk -F'\t' '{print $2}' "$probe")"
      if [[ "$code" =~ ^2|3 ]]; then
        stream_ok=$((stream_ok+1))
        stream_ttfb_total="$(awk -v a="$stream_ttfb_total" -v b="$sttfb" 'BEGIN{printf "%.6f", a+b}')"
      fi
    fi
  done

  if [ "$stream_ok" -gt 0 ]; then
    STREAM_TTFB_AVG_MS="$(awk -v sum="$stream_ttfb_total" -v n="$stream_ok" 'BEGIN{printf "%.0f", (sum/n)*1000}')"
  else
    STREAM_TTFB_AVG_MS="999999"
  fi

  STREAM_SCORE="$(awk -v ok="$stream_ok" -v avg="$STREAM_TTFB_AVG_MS" -v speed="$MBPS" 'BEGIN{
    s=(ok*25) + (speed*0.15) - (avg*0.05);
    if (s < 0) s = 0;
    printf "%.0f", s
  }')"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tOK\n" \
    "$PRETTY" "$EXIT_IP" "$COUNTRY" "$CITY" "$ORG" "$CONNECT_MS" "$TTFB_MS" "$MBPS" "$STREAM_SCORE" >> "$RESULTS"

  if awk -v a="$MBPS" -v b="$best_speed_value" 'BEGIN{exit !(a>b)}'; then
    best_speed_value="$MBPS"
    best_speed_name="$PRETTY"
  fi

  if awk -v c="$CONNECT_MS" -v bc="$best_latency_connect" -v t="$TTFB_MS" -v bt="$best_latency_ttfb" 'BEGIN{exit !((c<bc) || (c==bc && t<bt))}'; then
    best_latency_name="$PRETTY"
    best_latency_connect="$CONNECT_MS"
    best_latency_ttfb="$TTFB_MS"
  fi

  if awk -v a="$STREAM_SCORE" -v b="$best_stream_score" 'BEGIN{exit !(a>b)}'; then
    best_stream_score="$STREAM_SCORE"
    best_stream_name="$PRETTY"
  fi

done < "$EXITS_DB"

[ "$matched_count" -gt 0 ] || { echo "No matching exits found for this option."; exit 1; }
[ -s "$RESULTS" ] || { echo "No benchmark results were produced."; exit 1; }

sort -t $'\t' -k8,8nr "$RESULTS" > "$TMPDIR/sorted.tsv"

echo
case "$FILTER_MODE" in
  ALL) echo "Testing: All proxy exits" ;;
  HTTP) echo "Testing: All HTTP exits" ;;
  S5) echo "Testing: All SOCKS5 exits" ;;
  SS) echo "Testing: All Shadowsocks exits" ;;
esac
echo

RANK=1
while IFS=$'\t' read -r PRETTY EXIT_IP COUNTRY CITY ORG CONNECT_MS TTFB_MS MBPS STREAM_SCORE STATUS; do
  STATUS="${STATUS:-OK}"
  echo "$RANK) $PRETTY"
  echo "IP: $EXIT_IP"
  echo "Country: $COUNTRY"
  echo "City: $CITY"
  echo "Provider: $ORG"
  echo "Connect: ${CONNECT_MS} ms"
  echo "TTFB: ${TTFB_MS} ms"
  echo "Speed: ${MBPS} Mbps"
  echo "Streaming/Apps Score: ${STREAM_SCORE}"
  echo "Status: $STATUS"
  echo
  RANK=$((RANK+1))
done < "$TMPDIR/sorted.tsv"

echo "Best speed = ${best_speed_name} (${best_speed_value} Mbps)"
echo "Best latency = ${best_latency_name} (${best_latency_connect} ms connect / ${best_latency_ttfb} ms TTFB)"
echo "Best for Streaming / Apps = ${best_stream_name} (score ${best_stream_score})"
echo
echo "Done."
echo "TCP-only benchmark, fair across HTTP / SOCKS5 / Shadowsocks."
BENCH

chmod +x /usr/local/bin/bench

cat >/usr/local/lib/wireguard-proxy/update-routes <<'UPDATE'
#!/usr/bin/env bash
set -euo pipefail
/usr/local/lib/wireguard-proxy/build-routes
/usr/local/lib/wireguard-proxy/apply-routing
echo "Routes rebuilt and applied."
UPDATE
chmod +x /usr/local/lib/wireguard-proxy/update-routes

cat >/etc/systemd/system/wg-exit-update.service <<'SERVICE'
[Unit]
Description=Rebuild and apply WireGuard proxy exit routes

[Service]
Type=oneshot
ExecStart=/usr/local/lib/wireguard-proxy/update-routes
SERVICE

cat >/etc/systemd/system/wg-exit-update.timer <<'TIMER'
[Unit]
Description=Run WireGuard proxy exit route update every 3 minutes

[Timer]
OnBootSec=45s
OnUnitActiveSec=3min
Unit=wg-exit-update.service
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now wg-exit-update.timer

apt update
apt install -y strongswan strongswan-pki libcharon-extra-plugins openssl uuid-runtime

BASE="/Wireguard"
IKE_DIR="$BASE/ikev2"
MAP_DIR="$BASE/maps"

mkdir -p "$IKE_DIR/ca" "$IKE_DIR/server" "$IKE_DIR/clients"
mkdir -p /etc/ipsec.d/cacerts /etc/ipsec.d/certs /etc/ipsec.d/private /etc/ipsec.d/clients
touch "$MAP_DIR/ikev2_map.db"

SERVER_IP="$(curl -4 -fsSL https://api.ipify.org)"

ipsec pki --gen --type rsa --size 4096 > "$IKE_DIR/ca/caKey.pem"
ipsec pki --self --ca --lifetime 3650 \
  --in "$IKE_DIR/ca/caKey.pem" \
  --dn "CN=Wireguard IKEv2 CA" \
  --outform pem > "$IKE_DIR/ca/caCert.pem"

ipsec pki --gen --type rsa --size 4096 > "$IKE_DIR/server/serverKey.pem"
ipsec pki --pub --in "$IKE_DIR/server/serverKey.pem" | \
ipsec pki --issue --lifetime 1825 \
  --cacert "$IKE_DIR/ca/caCert.pem" \
  --cakey "$IKE_DIR/ca/caKey.pem" \
  --dn "CN=$SERVER_IP" \
  --san "$SERVER_IP" \
  --flag serverAuth --flag ikeIntermediate \
  --outform pem > "$IKE_DIR/server/serverCert.pem"

echo "$SERVER_IP" > "$IKE_DIR/server/server_id"

cp "$IKE_DIR/ca/caCert.pem" /etc/ipsec.d/cacerts/
cp "$IKE_DIR/server/serverCert.pem" /etc/ipsec.d/certs/
cp "$IKE_DIR/server/serverKey.pem" /etc/ipsec.d/private/

cat >/etc/ipsec.conf <<CONF
config setup
    uniqueids=never

conn ikev2-base
    auto=add
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    dpdaction=clear

    left=%any
    leftid=$SERVER_IP
    leftcert=serverCert.pem
    leftsubnet=0.0.0.0/0

    right=%any
    rightauth=pubkey

include /etc/ipsec.d/clients/*.conf
CONF

echo ": RSA serverKey.pem" >/etc/ipsec.secrets

systemctl restart strongswan-starter || systemctl restart strongswan

cat >/usr/local/lib/wireguard-proxy/new-ikev2-profile <<'IKE'
#!/usr/bin/env bash
set -euo pipefail
umask 077

BASE="/Wireguard"
IKE_DIR="$BASE/ikev2"
IKE_MAP="$BASE/maps/ikev2_map.db"
EXITS_DIR="$BASE/exits"

SLUG="$1"
FINAL="$2"
DIR="$3"

[ -f "$EXITS_DIR/$SLUG.env" ] || { echo "Proxy exit not found: $SLUG"; exit 1; }
mkdir -p "$DIR"

SERVER_ID="$(cat "$IKE_DIR/server/server_id")"
CA_CERT="$IKE_DIR/ca/caCert.pem"
CA_KEY="$IKE_DIR/ca/caKey.pem"

USERNAME="$(printf '%s' "$FINAL" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
[ -n "$USERNAME" ] || USERNAME="ikev2-client"
# Keep punctuation-normalized names from sharing an IKEv2 identity.
USERNAME="${USERNAME:0:80}-$(printf '%s' "$FINAL" | sha256sum | cut -c1-12)"

USED="$(awk -F'|' '{print $1}' "$IKE_MAP" | grep -Eo '10\.9\.0\.[0-9]+' | awk -F. '{print $4}' | sort -n | uniq || true)"
IP=""
for o in $(seq 2 254); do
  if ! echo "$USED" | grep -qx "$o"; then
    IP="10.9.0.$o"
    break
  fi
done
[ -n "$IP" ] || { echo "No IPs left in 10.9.0.0/24"; exit 1; }

KEY="$DIR/$FINAL-ikev2-key.pem"
CERT="$DIR/$FINAL-ikev2-cert.pem"
P12="$DIR/$FINAL.p12"
PASS_FILE="$DIR/$FINAL-p12-password.txt"
PROFILE="$DIR/$FINAL.mobileconfig"

PASS="$(openssl rand -base64 12)"

ipsec pki --gen --type rsa --size 2048 > "$KEY"
ipsec pki --pub --in "$KEY" | ipsec pki --issue \
  --cacert "$CA_CERT" --cakey "$CA_KEY" \
  --dn "CN=$USERNAME" \
  --san "$USERNAME" \
  --flag clientAuth \
  --outform pem > "$CERT"

openssl pkcs12 -export -inkey "$KEY" -in "$CERT" -certfile "$CA_CERT" \
  -out "$P12" -passout pass:$PASS

echo "$PASS" > "$PASS_FILE"

cat > /etc/ipsec.d/clients/$USERNAME.conf <<CONF
conn ikev2-$USERNAME
    also=ikev2-base
    rightid="$USERNAME"
    rightsourceip=$IP
CONF

systemctl restart strongswan-starter || systemctl restart strongswan

CA_B64=$(openssl x509 -in "$CA_CERT" -outform der | base64 -w0)
P12_B64=$(base64 -w0 "$P12")
ROOT_UUID="$(uuidgen)"
P12_UUID="$(uuidgen)"
VPN_UUID="$(uuidgen)"
PROFILE_UUID="$(uuidgen)"
PROFILE_ID="com.waqaar.wireguard-proxy.${USERNAME}"

FINAL_XML="$(python3 - "$FINAL" <<'ESCAPE'
import html, sys
print(html.escape(sys.argv[1]))
ESCAPE
)"
cat > "$PROFILE" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>PayloadContent</key><array>

<dict>
<key>PayloadDisplayName</key><string>WireGuard Proxy CA</string>
<key>PayloadIdentifier</key><string>$PROFILE_ID.ca</string>
<key>PayloadUUID</key><string>$ROOT_UUID</string>
<key>PayloadVersion</key><integer>1</integer>
<key>PayloadType</key><string>com.apple.security.root</string>
<key>PayloadContent</key><data>$CA_B64</data>
</dict>

<dict>
<key>PayloadDisplayName</key><string>$FINAL_XML Certificate</string>
<key>PayloadIdentifier</key><string>$PROFILE_ID.certificate</string>
<key>PayloadUUID</key><string>$P12_UUID</string>
<key>PayloadVersion</key><integer>1</integer>
<key>Password</key><string>$PASS</string>
<key>PayloadType</key><string>com.apple.security.pkcs12</string>
<key>PayloadContent</key><data>$P12_B64</data>
</dict>

<dict>
<key>PayloadDisplayName</key><string>$FINAL_XML VPN</string>
<key>PayloadIdentifier</key><string>$PROFILE_ID.vpn</string>
<key>PayloadUUID</key><string>$VPN_UUID</string>
<key>PayloadVersion</key><integer>1</integer>
<key>PayloadType</key><string>com.apple.vpn.managed</string>
<key>UserDefinedName</key><string>$FINAL_XML</string>
<key>VPNType</key><string>IKEv2</string>
<key>IKEv2</key>
<dict>
<key>AuthenticationMethod</key><string>Certificate</string>
<key>PayloadCertificateUUID</key><string>$P12_UUID</string>
<key>RemoteAddress</key><string>$SERVER_ID</string>
<key>RemoteIdentifier</key><string>$SERVER_ID</string>
<key>LocalIdentifier</key><string>$USERNAME</string>
</dict>
</dict>

</array>
<key>PayloadDisplayName</key><string>$FINAL_XML</string>
<key>PayloadIdentifier</key><string>$PROFILE_ID.profile</string>
<key>PayloadOrganization</key><string>Waqaar</string>
<key>PayloadScope</key><string>System</string>
<key>PayloadType</key><string>Configuration</string>
<key>PayloadUUID</key><string>$PROFILE_UUID</string>
<key>PayloadVersion</key><integer>1</integer>
</dict></plist>
XML

PUBLIC_DIR="/var/lib/wireguard-proxy-public"
mkdir -p "$PUBLIC_DIR"
chmod 755 "$PUBLIC_DIR"

LAST_NUMBER="$(find "$PUBLIC_DIR" -maxdepth 1 -type f -name 'p*.mobileconfig' -printf '%f\n' | sed -n 's/^p\([0-9][0-9]*\)\.mobileconfig$/\1/p' | sort -n | tail -n1)"
LAST_NUMBER="${LAST_NUMBER:-0}"
PROFILE_SHORT="p$((LAST_NUMBER + 1)).mobileconfig"
install -m 644 "$PROFILE" "$PUBLIC_DIR/$PROFILE_SHORT"

printf '%s|%s|%s|%s|%s\n' "$IP" "$SLUG" "$FINAL" "$USERNAME" "$PROFILE_SHORT" >> "$IKE_MAP"

systemctl start wg-http

echo
echo "Apple TV / IKEv2 profile:"
echo "  http://$SERVER_ID:8080/$PROFILE_SHORT"
IKE

chmod +x /usr/local/lib/wireguard-proxy/new-ikev2-profile

IFACE=$(ip route | awk '/default/ {print $5; exit}')

iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o "$IFACE" -j MASQUERADE

iptables -C INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 500 -j ACCEPT
iptables -C INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 4500 -j ACCEPT
iptables -C FORWARD -s 10.9.0.0/24 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -s 10.9.0.0/24 -j ACCEPT
iptables -C FORWARD -d 10.9.0.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -d 10.9.0.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

netfilter-persistent save >/dev/null 2>&1 || true

PORT=8080
PUBLIC_DIR="/var/lib/wireguard-proxy-public"
mkdir -p "$PUBLIC_DIR"
chmod 755 "$PUBLIC_DIR"

cat >/etc/systemd/system/wg-http.service <<SERVICE
[Unit]
Description=Wireguard HTTP profile server
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=$PUBLIC_DIR
ExecStart=/usr/bin/python3 -m http.server $PORT
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable wg-http

iptables -C INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 8080 -j ACCEPT
netfilter-persistent save >/dev/null 2>&1 || true

cat >/usr/local/bin/manage <<'MANAGE'
#!/usr/bin/env bash
set -euo pipefail

echo
echo "Manage WireGuard / IKEv2 Proxy"
echo "  [1] Edit a proxy"
echo "  [2] Remove a client and all its profiles"
echo "  [3] Check clients"
echo "  [4] Reapply routes"
echo "  [5] Sync missing profiles for all clients / proxies"
echo "  [6] Show saved profiles, QR and Apple TV links"
echo "  [0] Cancel"
echo

read -r -p "Choice: " choice
[[ "$choice" =~ ^[0-9]+$ ]] || { echo "Not a number."; exit 1; }

case "$choice" in
  1) exec /usr/local/lib/wireguard-proxy/edit-proxy ;;
  2) exec /usr/local/lib/wireguard-proxy/remove-client ;;
  3) exec /usr/local/lib/wireguard-proxy/check-clients ;;
  4) exec /usr/local/lib/wireguard-proxy/update-routes ;;
  5) exec python3 /usr/local/lib/wireguard-proxy/client-manager sync ;;
  6) exec python3 /usr/local/lib/wireguard-proxy/client-manager show ;;
  0) echo "Cancelled." ;;
  *) echo "Invalid choice"; exit 1 ;;
esac
MANAGE

chmod +x /usr/local/bin/manage

cat >/usr/local/bin/helper <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail

# Request root access when a tool is selected; the menu itself needs none.
run_tool() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$1"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -- "$1"
  else
    echo "Root access is required. Run helper as root or install sudo." >&2
    return 1
  fi
}

while true; do
  echo
  echo "WireGuard / IKEv2 Proxy"
  echo "  [1] Add a proxy exit"
  echo "  [2] Create a client / Apple profile"
  echo "  [3] Manage proxies, clients and routes"
  echo "  [4] Benchmark proxy exits"
  echo "  [0] Exit"
  echo

  if ! read -r -p "Choice: " choice; then
    echo
    exit 0
  fi

  case "$choice" in
    1) tool=add ;;
    2) tool=new ;;
    3) tool=manage ;;
    4) tool=bench ;;
    0|q|Q) exit 0 ;;
    *) echo "Invalid choice. Select 1 to 4, or 0 to exit."; continue ;;
  esac

  command_path="/usr/local/bin/$tool"
  if [ ! -x "$command_path" ]; then
    echo "Missing command: $command_path" >&2
    echo "This menu needs the project's existing helper commands installed." >&2
    continue
  fi

  echo
  if run_tool "$command_path"; then
    :
  else
    status=$?
    printf '\n%s exited with status %s. Returning to the main menu.\n' "$tool" "$status" >&2
  fi
done
HELPER
chmod +x /usr/local/bin/helper

systemctl daemon-reload

echo
echo "SETUP COMPLETE"
echo
echo "Main menu: helper"
echo
echo "Individual helpers:"
echo "  add"
echo "  new"
echo "  manage"
echo "  bench"
echo
echo "Notes:"
echo "  - Device DNS stays on the device."
echo "  - Client configs do NOT include DNS lines."
echo "  - 45.88.89.23 bypass stays direct."
echo "  - new creates WireGuard and Apple IKEv2 profiles."
echo
