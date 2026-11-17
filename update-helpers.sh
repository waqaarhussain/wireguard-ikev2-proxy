#!/usr/bin/env bash
# Update the command tools on an installed server without rerunning VPN setup.
set -euo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run with sudo bash update-helpers.sh"; exit 1; }
[ -f /etc/wireguard/wg0.conf ] && [ -f /Wireguard/maps/client_map.db ] && \
  [ -f /Wireguard/ikev2/ca/caCert.pem ] && [ -s /Wireguard/ikev2/server/server_id ] || { echo "An existing, completed VPN installation is required."; exit 1; }
umask 077
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
repo="waqaarhussain/wireguard-ikev2-proxy"
# Fetch all tools from a single immutable revision so updates cannot mix versions.
revision="$(curl -fsSL "https://api.github.com/repos/$repo/git/ref/heads/main" | python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["sha"])')"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid GitHub revision"; exit 1; }
sources=(add-proxy.sh new-client.sh manage.sh helper.sh create-profile.sh client-manager.py ikev2-profile.sh remove-client.sh)
targets=(/usr/local/bin/add /usr/local/bin/new /usr/local/bin/manage /usr/local/bin/helper
  /usr/local/lib/wireguard-proxy/create-profile /usr/local/lib/wireguard-proxy/client-manager
  /usr/local/lib/wireguard-proxy/new-ikev2-profile /usr/local/lib/wireguard-proxy/remove-client)
for source in "${sources[@]}"; do
  curl -fsSL "https://raw.githubusercontent.com/$repo/$revision/$source" -o "$stage/$source"
  [ -s "$stage/$source" ] || { echo "Empty download: $source"; exit 1; }
  if [[ "$source" = *.sh ]]; then
    bash -n "$stage/$source"
  else
    python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$stage/$source"
  fi
done
apt-get update
apt-get install -y qrencode
mkdir -p /var/backups
backup="$(mktemp -d /var/backups/wireguard-proxy-helpers.XXXXXXXX)"
for i in "${!sources[@]}"; do
  if [ -f "${targets[$i]}" ]; then
    cp -p -- "${targets[$i]}" "$backup/${sources[$i]}"
  fi
done
if [ -f /Wireguard/maps/clients.json ]; then
  cp -p /Wireguard/maps/clients.json "$backup/clients.json"
fi
echo "Previous helper tools backed up in: $backup"
mkdir -p /usr/local/lib/wireguard-proxy
for i in "${!sources[@]}"; do
  install -m 755 "$stage/${sources[$i]}" "${targets[$i]}"
done
python3 /usr/local/lib/wireguard-proxy/client-manager migrate
# Existing complete profiles are skipped. Only missing client/proxy pairs are added.
python3 /usr/local/lib/wireguard-proxy/client-manager sync
echo
echo "Helpers updated. Previous tools backed up in: $backup"
echo "Run helper to add a proxy, create a client, or view saved profiles."
