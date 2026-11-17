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
