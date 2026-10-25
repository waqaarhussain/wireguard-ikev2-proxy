#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run this installer as root: sudo bash install.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y wireguard wireguard-tools iptables iproute2 curl qrencode ca-certificates procps jq iptables-persistent python3

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

cat >/usr/local/bin/build-routes <<'BUILD'
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
chmod +x /usr/local/bin/build-routes

cat >/usr/local/bin/apply-routing <<'APPLY'
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
chmod +x /usr/local/bin/apply-routing

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
/usr/local/bin/build-routes

echo
read -r -p "Start/restart this exit now? [y/N]: " RESTART
case "${RESTART:-N}" in
  y|Y)
    systemctl restart "singbox-exit@${SLUG}" || systemctl start "singbox-exit@${SLUG}"
    ;;
esac

echo
read -r -p "Create client? [y/N]: " CREATE
case "${CREATE:-N}" in
  y|Y) /usr/local/bin/new-client "$SLUG" ;;
esac

echo
echo "Exit saved: ${LABEL} [${TYPE_TAG}]"
echo "Slug: $SLUG"
ADD
chmod +x /usr/local/bin/add

cat >/usr/local/bin/new-client <<'NEWCLIENT'
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

qrencode -t PNG -o "$DIR/$FINAL.png" < "$CONF"
chmod 600 "$CONF" "$DIR/$FINAL.png"

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

/usr/local/bin/new-ikev2-profile "$SLUG" "$FINAL" "$DIR"
/usr/local/bin/apply-routing

echo
echo "Client created:"
echo "  $FINAL"
echo "  $IP"
echo "  $DIR/$FINAL.conf"
echo "  $DIR/$FINAL.png"
echo "  $DIR/$FINAL.mobileconfig"
NEWCLIENT
chmod +x /usr/local/bin/new-client

cat >/usr/local/bin/edit <<'EDIT'
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
/usr/local/bin/build-routes
systemctl restart "singbox-exit@${SLUG}" || systemctl start "singbox-exit@${SLUG}"

echo "Updated: $LABEL [$TYPE_TAG]"
EDIT
chmod +x /usr/local/bin/edit

cat >/usr/local/bin/remove <<'REMOVE'
#!/usr/bin/env bash
set -euo pipefail

BASE="/Wireguard"
CLIENTS_DIR="$BASE/client"
WG_CONF="/etc/wireguard/wg0.conf"
MAP_DB="$BASE/maps/client_map.db"
PEERS_DB="$BASE/maps/peers.db"
IKE_MAP="$BASE/maps/ikev2_map.db"

mapfile -d '' DIRS < <(find "$CLIENTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
[ "${#DIRS[@]}" -gt 0 ] || { echo "No clients found."; exit 1; }

echo
echo "Clients:"
for i in "${!DIRS[@]}"; do
  printf "  [%d] %s\n" "$((i+1))" "$(basename "${DIRS[$i]}")"
done
echo
read -r -p "Select client number to remove: " choice
[[ "$choice" =~ ^[0-9]+$ ]] || { echo "Not a number."; exit 1; }
(( choice >= 1 && choice <= ${#DIRS[@]} )) || { echo "Out of range."; exit 1; }

TARGET_DIR="${DIRS[$((choice-1))]}"
NAME="$(basename "$TARGET_DIR")"

python3 - <<PY
import pathlib
wg_conf = pathlib.Path("$WG_CONF")
name = "$NAME"
text = wg_conf.read_text(encoding="utf-8", errors="ignore")
blocks = text.split("\\n\\n")
kept = []
for b in blocks:
    lines = [ln.strip() for ln in b.splitlines()]
    if "[Peer]" in lines and f"# {name}" in lines:
        continue
    kept.append(b)
wg_conf.write_text("\\n\\n".join(kept).rstrip()+"\\n", encoding="utf-8")
PY

grep -Fv "|$NAME" "$MAP_DB" > "$MAP_DB.tmp" || true
mv "$MAP_DB.tmp" "$MAP_DB"

grep -Fv "|$NAME|" "$PEERS_DB" > "$PEERS_DB.tmp" || true
mv "$PEERS_DB.tmp" "$PEERS_DB"

IKE_USERNAME=""
if [ -f "$IKE_MAP" ]; then
  IKE_USERNAME="$(awk -F'|' -v n="$NAME" '$3==n{print $4; exit}' "$IKE_MAP")"
  awk -F'|' -v n="$NAME" '$3!=n' "$IKE_MAP" > "$IKE_MAP.tmp"
  mv "$IKE_MAP.tmp" "$IKE_MAP"
fi

if [ -n "$IKE_USERNAME" ]; then
  rm -f -- "/etc/ipsec.d/clients/$IKE_USERNAME.conf"
  systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null || true
fi

if wg show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(wg-quick strip wg0)
else
  systemctl restart wg-quick@wg0
fi

/usr/local/bin/apply-routing
rm -rf -- "$TARGET_DIR"

echo "Removed: $NAME"
REMOVE
chmod +x /usr/local/bin/remove

cat >/usr/local/bin/check <<'CHECK'
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
chmod +x /usr/local/bin/check

ln -sf /usr/local/bin/new-client /usr/local/bin/new

echo "HELPERS DONE"

iptables -C INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport 51820 -j ACCEPT
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
netfilter-persistent save >/dev/null 2>&1 || true

/usr/local/bin/build-routes
/usr/local/bin/apply-routing || true

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

cat >/usr/local/bin/update <<'UPDATE'
#!/usr/bin/env bash
set -euo pipefail
/usr/local/bin/build-routes
/usr/local/bin/apply-routing
echo "Routes rebuilt and applied."
UPDATE
chmod +x /usr/local/bin/update

cat >/etc/systemd/system/wg-exit-update.service <<'SERVICE'
[Unit]
Description=Rebuild and apply WireGuard proxy exit routes

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update
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

cat >/usr/local/bin/new-ikev2-profile <<'IKE'
#!/usr/bin/env bash
set -euo pipefail

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

printf '%s|%s|%s|%s\n' "$IP" "$SLUG" "$FINAL" "$USERNAME" >> "$IKE_MAP"

systemctl restart strongswan-starter || systemctl restart strongswan

CA_B64=$(openssl x509 -in "$CA_CERT" -outform der | base64 -w0)
P12_B64=$(base64 -w0 "$P12")
ROOT_UUID="$(uuidgen)"
P12_UUID="$(uuidgen)"
VPN_UUID="$(uuidgen)"
PROFILE_UUID="$(uuidgen)"
PROFILE_ID="com.waqaar.wireguard-proxy.${USERNAME}"

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
<key>PayloadDisplayName</key><string>$FINAL Certificate</string>
<key>PayloadIdentifier</key><string>$PROFILE_ID.certificate</string>
<key>PayloadUUID</key><string>$P12_UUID</string>
<key>PayloadVersion</key><integer>1</integer>
<key>Password</key><string>$PASS</string>
<key>PayloadType</key><string>com.apple.security.pkcs12</string>
<key>PayloadContent</key><data>$P12_B64</data>
</dict>

<dict>
<key>PayloadDisplayName</key><string>$FINAL VPN</string>
<key>PayloadIdentifier</key><string>$PROFILE_ID.vpn</string>
<key>PayloadUUID</key><string>$VPN_UUID</string>
<key>PayloadVersion</key><integer>1</integer>
<key>PayloadType</key><string>com.apple.vpn.managed</string>
<key>UserDefinedName</key><string>$FINAL</string>
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
<key>PayloadDisplayName</key><string>$FINAL</string>
<key>PayloadIdentifier</key><string>$PROFILE_ID.profile</string>
<key>PayloadOrganization</key><string>Waqaar</string>
<key>PayloadScope</key><string>System</string>
<key>PayloadType</key><string>Configuration</string>
<key>PayloadUUID</key><string>$PROFILE_UUID</string>
<key>PayloadVersion</key><integer>1</integer>
</dict></plist>
XML

echo "IKEv2 CREATED: $PROFILE"
IKE

chmod +x /usr/local/bin/new-ikev2-profile

IFACE=$(ip route | awk '/default/ {print $5; exit}')

iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o "$IFACE" -j MASQUERADE

iptables -C INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 500 -j ACCEPT
iptables -C INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 4500 -j ACCEPT
iptables -C FORWARD -s 10.9.0.0/24 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -s 10.9.0.0/24 -j ACCEPT
iptables -C FORWARD -d 10.9.0.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -d 10.9.0.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

netfilter-persistent save >/dev/null 2>&1 || true

PORT=8080
PUBLIC_DIR="/Wireguard/public"
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
systemctl enable --now wg-http

cat >/usr/local/bin/apple-tv <<'APP'
#!/usr/bin/env bash
set -euo pipefail

ROOT="/Wireguard/client"
PUBLIC_DIR="/Wireguard/public"
PORT=8080
IP="$(curl -4 -fsSL https://api.ipify.org)"

find "$PUBLIC_DIR" -maxdepth 1 -type f -name 'p*.mobileconfig' -delete

echo
echo "Apple TV Profiles (SHORT LINKS):"
echo

i=1

find "$ROOT" -type f -name "*.mobileconfig" | sort | while read -r f; do
  name="$(basename "$f")"

  short="p$i.mobileconfig"
  install -m 644 "$f" "$PUBLIC_DIR/$short"

  url="http://$IP:$PORT/$short"

  echo "[$i] $name"
  echo "    $url"
  echo

  i=$((i+1))
done
APP

chmod +x /usr/local/bin/apple-tv

iptables -C INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 8080 -j ACCEPT
netfilter-persistent save >/dev/null 2>&1 || true

cat >/usr/local/bin/helpers <<'H'
#!/usr/bin/env bash
set -euo pipefail

HELPER_DIR="/usr/local/bin"
SELF_NAME="helpers"

mapfile -t AVAILABLE_CMDS < <(
  find "$HELPER_DIR" -maxdepth 1 -type f -perm -111 -printf '%f\n' |
  sort |
  awk -v self="$SELF_NAME" '
    $0 != self &&
    $0 !~ /^(apply-routing|build-routes|sing-box|wg|wg-quick)$/ &&
    $0 !~ /^(apt|apt-get|bash|sh|dash|ls|cat|cp|mv|rm|sed|awk|grep|find|sort|head|tail|chmod|chown|systemctl|journalctl|ip|curl|jq|python3|nano|vi|vim|less|more|scp|sftp|ssh|sshd|tar|gzip|gunzip|unzip|zip|tee|touch|mkdir|mktemp|env|printenv|xargs|dirname|basename|cut|tr|printf|echo|sleep|kill|pkill|pgrep|ps|du|df|mount|umount|ln|realpath)$/'
)

if [ "${#AVAILABLE_CMDS[@]}" -eq 0 ]; then
  echo "No helpers found."
  exit 1
fi

echo
echo "Available helpers:"
for i in "${!AVAILABLE_CMDS[@]}"; do
  printf "  [%d] %s\n" "$((i+1))" "${AVAILABLE_CMDS[$i]}"
done
echo
echo "  [0] Cancel"
echo

read -r -p "Pick helper number: " choice
[[ "$choice" =~ ^[0-9]+$ ]] || { echo "Not a number."; exit 1; }

if [ "$choice" -eq 0 ]; then
  echo "Cancelled."
  exit 0
fi

(( choice >= 1 && choice <= ${#AVAILABLE_CMDS[@]} )) || { echo "Out of range."; exit 1; }

CMD="${AVAILABLE_CMDS[$((choice-1))]}"

echo
echo "Running: $CMD"
echo

exec "$CMD"
H

chmod +x /usr/local/bin/helpers

systemctl daemon-reload

echo
echo "SETUP COMPLETE"
echo
echo "Helpers:"
echo "  add"
echo "  new"
echo "  edit"
echo "  remove"
echo "  check"
echo "  bench"
echo "  update"
echo "  apple-tv"
echo "  helpers"
echo
echo "Notes:"
echo "  - Device DNS stays on the device."
echo "  - Client configs do NOT include DNS lines."
echo "  - 45.88.89.23 bypass stays direct."
echo "  - check uses a 60-second active window."
echo
