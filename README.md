# WireGuard / IKEv2 Proxy

Installs WireGuard, StrongSwan IKEv2 and sing-box on a fresh Ubuntu VPS. WireGuard clients can be assigned to stored HTTP, SOCKS5 or Shadowsocks proxy exits.

## Install

Run on a fresh Ubuntu VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/wireguard-ikev2-proxy/main/install.sh -o /tmp/wireguard-ikev2-proxy-install.sh && sudo bash /tmp/wireguard-ikev2-proxy-install.sh
```

## Helpers

- `add`: add a proxy exit
- `new`: create a WireGuard client
- `edit`: edit a proxy exit
- `remove`: remove a client
- `check`: list clients and recent activity
- `bench`: benchmark proxy exits
- `update`: rebuild and apply routes
- `apple-tv`: publish generated Apple configuration profiles
- `helpers`: interactive helper menu

## Important

- Designed for a fresh Ubuntu installation.
- Proxy credentials and generated private keys stay on the VPS and are not stored in this repository.
- Port 8080 serves only profiles copied into `/Wireguard/public`.
- Apple profile links use plain HTTP and remain reachable until removed or the service is stopped.
