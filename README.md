# WireGuard / IKEv2 Proxy

A fresh Ubuntu VPS installer that lets WireGuard and IKEv2 clients use HTTP, SOCKS5 or Shadowsocks proxy exits stored on the server.

Each saved client can have a separate WireGuard and Apple IKEv2 profile for each proxy exit. Each profile is assigned to exactly one exit. The VPS accepts the encrypted client connection, applies source-based routing and sends that client's traffic through the selected sing-box proxy tunnel.

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

## Main menu

After installation, type:

```bash
helper
```

Select a numbered option to add a proxy, create a client, open management or benchmark exits. The menu returns after the selected command finishes, including when a command fails. Select `0` to exit. If you are not root, `helper` requests sudo access when you select a tool.

### Add the menu to an existing server

Install only the menu without rerunning the full VPN installer:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/wireguard-ikev2-proxy/main/helper.sh -o /tmp/wireguard-proxy-helper.sh && sudo install -m 755 /tmp/wireguard-proxy-helper.sh /usr/local/bin/helper && helper
```

This adds the launcher and leaves the existing VPN configuration, certificates, clients and proxies unchanged. The existing `add`, `new`, `manage` and `bench` commands must already be installed.

## Clients and proxy countries

Save a client once, such as `Waqaar iPhone` or `Living Room Apple TV`. Its country profiles are separate connections with their own keys, addresses and routing. Installing another country profile does not replace an existing one.

| Action | Result |
| --- | --- |
| Add a new proxy/country | Automatically generate WireGuard and Apple IKEv2 profiles for every saved client on that new exit |
| Create a client | Enter the client name, then select one proxy or **All proxies** (the default) |
| Create a client before adding any proxies | Save the name now; adding a proxy later generates its profiles |
| Enter an existing client name again | Add missing profiles for the selected exits, reusing the saved client |
| Manage > Sync missing profiles | Fill all missing client/proxy combinations; skip completed profiles |
| Manage > Show saved profiles | Select a client and country to display its compact WireGuard QR and Apple TV link |
| Manage > Remove a client | Remove the saved client and all its country profiles after confirmation |

For example, if Alice and Bob already have UK profiles, adding France generates `Alice / France` and `Bob / France`. Their UK profiles, keys and installation links remain unchanged. Bulk creation prints the file locations and Apple TV links without filling the terminal with multiple QR codes. Use **Show saved profiles** to display a QR for one profile at a time.

A client created for only one existing proxy receives profiles for future new proxies automatically. To backfill its other existing proxies, choose **Sync missing profiles**. Automatic sync runs when a proxy is added; it does not periodically recreate deleted files.

## First use

Run `helper` and choose **Create a client / Apple profile**, or run:

```bash
sudo new
```

Enter the client name first. If proxies are available, choose one or press Enter for all. With no proxies, the name is saved for later.

Add a proxy using `helper` or:

```bash
sudo add
```

Choose HTTP, SOCKS5 or Shadowsocks, then enter the proxy details. After saving the exit, profiles for all saved clients are generated automatically. With no saved clients, the exit is saved and you can create a client later.

Each client/proxy pair gets:

- A WireGuard `.conf` file and independent server peer
- An IKEv2 client certificate and password-protected PKCS#12 certificate
- An Apple `.mobileconfig` profile and short Apple TV installation link
- WireGuard and IKEv2 source-routing entries for that proxy

For a single profile, the final output displays a half-height WireGuard QR and the Apple TV link. Scan the QR in the WireGuard app. QR dimensions depend on the configuration length and terminal font.

Profile files retain the existing folder layout:

```text
/Wireguard/client/CLIENT - [TYPE - COUNTRY]/
```

### Update an existing server

Run the helper updater, **not the full VPN installer**:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/wireguard-ikev2-proxy/main/update-helpers.sh -o /tmp/wireguard-proxy-update-helpers.sh && sudo bash /tmp/wireguard-proxy-update-helpers.sh
```

The updater downloads the helper tools from a single GitHub revision, checks their syntax, installs `qrencode`, backs up the previous helper tools in `/var/backups`, and imports existing clients in place. Legacy names such as `Alice - [S5 - UK]` and `Alice - [S5 - France]` are grouped under `Alice`. Existing profile files, keys and the VPN certificate authority are preserved. Then it fills any missing client/proxy combinations. It does not create a new proxy or replace completed profiles.

If a creation attempt fails, its saved client remains registered. **Sync missing profiles** retries the incomplete pair while reusing an already-created WireGuard config. A missing file belonging to an existing mapped profile is reported for restoration from backup rather than silently changing its keys. The sync checks address capacity before a bulk run. The current subnets provide 253 profile addresses each, from `.2` to `.254`; each client/proxy pair consumes one address in each subnet.

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

Removing a client through `manage` removes all of its country profiles and their published downloads. **Show saved profiles** restarts the profile web server if needed and republishes a missing download from the saved local profile.

## Helper commands

Use `helper` as the main menu, or run an individual command directly:

| Command | Purpose |
| --- | --- |
| `helper` | Open the main menu for all four tools |
| `add` | Add a proxy exit and automatically create its profiles for all saved clients |
| `new` | Save a client and create WireGuard/Apple profiles for one or all exits |
| `manage` | Edit proxies, remove clients, check profiles, apply routes, sync missing profiles or view QR codes and Apple links |
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
| `/Wireguard/maps/clients.json` | Saved client names, including clients with no profiles yet |
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
- Removing a saved client deletes all its WireGuard peers, IKEv2 identities and route mappings across countries.

## Basic checks

```bash
sudo systemctl status wg-quick@wg0 --no-pager
sudo systemctl status strongswan-starter --no-pager
sudo systemctl list-timers --all | grep wg-exit-update
sudo manage # Choose 3 to check clients
```

To inspect a specific proxy exit:

```bash
sudo systemctl status singbox-exit@EXIT-SLUG --no-pager
sudo journalctl -u singbox-exit@EXIT-SLUG -n 100 --no-pager
```
