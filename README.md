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
- WireGuard configuration files
- Proxy benchmarking
- Automatic route rebuilding every three minutes
- Automatic short Apple profile links on TCP port `8080`

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
- An IKEv2 client certificate
- A password-protected PKCS#12 certificate
- An Apple `.mobileconfig` profile
- A short Apple TV installation link
- WireGuard and IKEv2 source-routing entries for the selected proxy

Client files are stored in:

```text
/Wireguard/client/CLIENT NAME/
```

## Apple TV and Apple profile installation

The `new` command automatically copies the generated `.mobileconfig` file into a dedicated download directory, starts the restricted profile server and prints a short link such as:

```text
http://SERVER-IP:8080/p1.mobileconfig
```

No separate `apple-tv` command is needed. Open the printed link on the Apple device that needs the profile.

The profile contains a client private certificate and its import password. The link uses plain HTTP and is publicly reachable while the service is running. Install the profile, then stop the profile server:

```bash
sudo systemctl stop wg-http
```

The published profile remains in `/var/lib/wireguard-proxy-public`. To use the same link again:

```bash
sudo systemctl start wg-http
```

Removing a client through `manage` also removes its published profile.

## Helper commands

Only four public commands are installed:

| Command | Purpose |
| --- | --- |
| `add` | Add an HTTP, SOCKS5 or Shadowsocks proxy exit, with an option to create a client immediately |
| `new` | Create WireGuard and Apple IKEv2 client profiles, apply proxy routing and print the Apple TV link |
| `manage` | Edit a proxy, remove a client, check clients or manually reapply routes |
| `bench` | Benchmark all exits or filter by proxy type |

Route building, profile publishing and the three-minute refresh timer run internally and do not add extra user commands.

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
| `/var/lib/wireguard-proxy-public` | Profiles intentionally exposed by `wg-http` |

The top-level `/Wireguard` directory is root-only. Only files copied into `/var/lib/wireguard-proxy-public` are readable by the restricted HTTP service.

## DNS behaviour

Client configurations do not contain a DNS setting. The connected device keeps its own configured DNS resolver.

## Security notes

- Proxy credentials and generated private keys stay on the VPS.
- The HTTP profile service runs as `www-data` and serves only `/var/lib/wireguard-proxy-public`.
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
