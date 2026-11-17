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
