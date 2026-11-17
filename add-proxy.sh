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
