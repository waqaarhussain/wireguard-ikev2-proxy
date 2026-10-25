# WireGuard / IKEv2 Proxy

A fresh Ubuntu VPS installer that lets WireGuard and IKEv2 clients use HTTP, SOCKS5 or Shadowsocks proxy exits stored on the server.

Each client is assigned to one proxy exit. The VPS accepts the encrypted client connection, applies source-based routing and sends that client's traffic through the selected sing-box proxy tunnel.

## What it installs

- WireGuard server on UDP port `51820`
- StrongSwan IKEv2 server on UDP ports `500` and `4500`
- Latest sing-box Linux AMD64 release
- Per-proxy sing-box TUN interfaces
- Per-client policy routing
- Apple-compatible certificate profiles
- QR codes and WireGuard configuration files
- Proxy benchmarking
- Automatic route rebuilding every three minutes
- Optional temporary HTTP profile delivery on TCP port `8080`

## Supported proxy exits

- HTTP proxy with username and password
- SOCKS5 with IP allowlisting
- SOCKS5 with username and password
- Shadowsocks with selectable encryption method

Proxy credentials are entered after installation using the `add` helper. They are never stored in this GitHub repository.

## Traffic flow

1. A device connects using WireGuard or IKEv2.
2. The VPS assigns the client a private address.
3. The client's address is mapped to its selected proxy exit.
4. Linux policy routing sends that source address to the correct sing-box TUN interface.
5. sing-box forwards the traffic through the stored HTTP, SOCKS5 or Shadowsocks proxy.
6. The `45.88.89.23` bypass remains routed directly through the VPS main connection.

WireGuard uses `10.8.0.0/24`. IKEv2 uses `10.9.0.0/24`.

## Requirements

- Fresh Ubuntu VPS
- AMD64 or x86_64 processor
- Root or sudo access
- Public IPv4 address
- Provider firewall access for the required ports
- A working upstream HTTP, SOCKS5 or Shadowsocks proxy

## Fresh Ubuntu installation

Run:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/wireguard-ikev2-proxy/main/install.sh -o /tmp/wireguard-ikev2-proxy-install.sh && sudo bash /tmp/wireguard-ikev2-proxy-install.sh
```

The installer downloads sing-box from its official GitHub release, installs the required Ubuntu packages, creates the WireGuard and IKEv2 certificate infrastructure, configures routing and enables the required services.

This installer is intended for a fresh server. Do not rerun it on a configured server because it recreates `wg0.conf` and the IKEv2 certificate authority.

## First use

Add a proxy exit:

```bash
sudo add
```

Choose HTTP, SOCKS5 or Shadowsocks, then enter the proxy details.

Create a client:

```bash
sudo new
```

Choose the proxy exit and enter a client name. The helper creates:

- A WireGuard `.conf` file
- A WireGuard QR code
- An IKEv2 client certificate
- A password-protected PKCS#12 certificate
- An Apple `.mobileconfig` profile
- WireGuard and IKEv2 source-routing entries for the selected proxy

Client files are stored in:

```text
/Wireguard/client/CLIENT NAME/
```

## Apple TV and Apple profile installation

List short profile links:

```bash
sudo apple-tv
```

This copies generated `.mobileconfig` files into `/Wireguard/public` and serves only that directory on TCP port `8080`.

The profile contains a client private certificate and its import password. The link uses plain HTTP and is publicly reachable while the service is running. Install the profile, then stop the profile server:

```bash
sudo systemctl disable --now wg-http
sudo find /Wireguard/public -maxdepth 1 -type f -name '*.mobileconfig' -delete
```

To use the links again:

```bash
sudo systemctl enable --now wg-http
sudo apple-tv
```

## Helper commands

| Command | Purpose |
| --- | --- |
| `add` | Add an HTTP, SOCKS5 or Shadowsocks proxy exit |
| `new` | Create matching WireGuard and IKEv2 client profiles |
| `edit` | Edit an existing proxy exit |
| `remove` | Remove a client, its peer, IKEv2 identity and route mappings |
| `check` | List WireGuard clients and mark recent handshakes |
| `bench` | Benchmark all exits or filter by proxy type |
| `update` | Rebuild and apply local route mappings |
| `apple-tv` | Publish short Apple profile links |
| `helpers` | Open an interactive helper menu |

The `update` helper refreshes local routing. It does not download updates from GitHub.

## Benchmarking

Run:

```bash
sudo bench
```

The benchmark checks exit identity, country, city, provider, connection latency, time to first byte, TCP download speed and reachability of several streaming or application websites.

The displayed streaming score is a local comparison score. It is not a guarantee that a streaming service will work or remain unblocked.

## Required inbound ports

| Protocol | Port | Purpose |
| --- | ---: | --- |
| UDP | 51820 | WireGuard |
| UDP | 500 | IKEv2 |
| UDP | 4500 | IKEv2 NAT traversal |
| TCP | 22 | SSH |
| TCP | 8080 | Temporary Apple profile delivery |

TCP port `8080` is optional after Apple profiles have been installed.

## Services and timer

| Unit | Purpose |
| --- | --- |
| `wg-quick@wg0.service` | WireGuard server |
| `strongswan-starter.service` | IKEv2 server |
| `singbox-exit@NAME.service` | One sing-box process per proxy exit |
| `wg-exit-update.timer` | Reapply route mappings every three minutes |
| `wg-http.service` | Optional Apple profile web server |

## Important locations

| Path | Contents |
| --- | --- |
| `/etc/wireguard/wg0.conf` | WireGuard server and peer configuration |
| `/Wireguard/server` | WireGuard server keys |
| `/Wireguard/client` | Generated client configurations and profiles |
| `/Wireguard/exits` | Root-only proxy definitions and credentials |
| `/Wireguard/proxies` | Generated sing-box configuration files |
| `/Wireguard/maps/client_map.db` | WireGuard client-to-exit mappings |
| `/Wireguard/maps/ikev2_map.db` | IKEv2 client-to-exit mappings |
| `/Wireguard/ikev2` | IKEv2 CA, server certificate and client assets |
| `/Wireguard/public` | Profiles intentionally exposed by `wg-http` |

The top-level `/Wireguard` directory is root-only. Files copied into `/Wireguard/public` are deliberately made readable by the restricted HTTP service.

## DNS behaviour

Client configurations do not contain a DNS setting. The connected device keeps its own configured DNS resolver.

## Security notes

- Proxy credentials and generated private keys stay on the VPS.
- The HTTP profile service runs as `www-data` and can access only the dedicated public profile directory.
- Apple profiles contain sensitive client credentials. Do not leave TCP port `8080` open unnecessarily.
- The profile server uses HTTP rather than HTTPS. Use it only for short-lived installation on a network you trust.
- Back up `/Wireguard` before replacing or rebuilding the VPS.
- Removing a client deletes its active WireGuard peer, IKEv2 identity and route mappings.

## Basic checks

```bash
sudo systemctl status wg-quick@wg0 --no-pager
sudo systemctl status strongswan-starter --no-pager
sudo systemctl list-timers --all | grep wg-exit-update
sudo check
```

To inspect a specific proxy exit:

```bash
sudo systemctl status singbox-exit@EXIT-SLUG --no-pager
sudo journalctl -u singbox-exit@EXIT-SLUG -n 100 --no-pager
```
