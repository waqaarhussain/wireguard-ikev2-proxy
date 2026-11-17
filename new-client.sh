#!/usr/bin/env bash
set -euo pipefail
[ -f /usr/local/lib/wireguard-proxy/client-manager ] || {
  echo "Client tools need updating. Run the update-helpers.sh command from the project README." >&2
  exit 1
}
exec python3 /usr/local/lib/wireguard-proxy/client-manager new "$@"
