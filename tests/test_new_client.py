"""Run client creation against fake VPN tools and isolated server files."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NewClientTests(unittest.TestCase):
    def test_installer_matches_standalone_client(self):
        installer = (ROOT / 'install.sh').read_text()
        embedded = installer.split("cat >/usr/local/bin/new <<'NEWCLIENT'\n", 1)[1]
        embedded = embedded.split('\nNEWCLIENT\n', 1)[0] + '\n'
        self.assertEqual(embedded, (ROOT / 'new-client.sh').read_text())
        subprocess.run(['bash', '-n', str(ROOT / 'new-client.sh')], check=True)

    def run_client(self, qr_status=0, ike_status=0):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        for directory in ('server', 'maps', 'exits', 'client', 'bin', 'lib'):
            (base / directory).mkdir()
        (base / 'server/server_publickey').write_text('TEST_SERVER_KEY\n')
        (base / 'maps/exits.db').write_text('test|proxy|UK [SOCKS5]|tun1|1001\n')
        for name in ('client_map.db', 'peers.db'):
            (base / 'maps' / name).touch()
        (base / 'exits/test.env').write_text('SLUG=test\nTYPE_TAG=SOCKS5\nLABEL=UK\n')
        (base / 'wg0.conf').write_text('[Interface]\n')

        def stub(path, content):
            path.write_text('#!/bin/bash\nset -eu\n' + content + '\n')
            path.chmod(0o755)

        stub(base / 'bin/curl', 'echo 192.0.2.10')
        stub(base / 'bin/wg', '''case "$1" in
          genkey) echo TEST_PRIVATE_KEY ;;
          pubkey) cat >/dev/null; echo TEST_CLIENT_PUBLIC_KEY ;;
          syncconf) cat "$3" >/dev/null ;;
          show) exit 0 ;;
          *) exit 90 ;;
        esac''')
        stub(base / 'bin/wg-quick', 'echo "[Interface]"')
        stub(base / 'bin/systemctl', 'exit 91')
        stub(base / 'bin/qrencode', '''printf '%s\\n' "$@" > "$TEST_BASE/qr-args"
cat > "$TEST_BASE/qr-input"
echo COMPACT_QR
exit ''' + str(qr_status))
        stub(base / 'lib/apply-routing', 'touch "$TEST_BASE/routes-applied"')
        stub(base / 'lib/new-ikev2-profile', '''printf '%s\\n' "$@" > "$TEST_BASE/ike-args"
if [ ''' + str(ike_status) + ''' -ne 0 ]; then
  echo "Profile error details"
  exit ''' + str(ike_status) + '''
fi
touch "$3/$2.mobileconfig"
printf '\\nApple TV / IKEv2 profile:\\n  http://192.0.2.10:8080/p1.mobileconfig\\n' ''')
        script = (ROOT / 'new-client.sh').read_text()
        script = script.replace('/Wireguard', str(base))
        script = script.replace('/etc/wireguard/wg0.conf', str(base / 'wg0.conf'))
        script = script.replace('/usr/local/lib/wireguard-proxy/', str(base / 'lib') + '/')
        (base / 'new').write_text(script)
        env = dict(os.environ, PATH=str(base / 'bin') + ':' + os.environ['PATH'],
                   TEST_BASE=str(base))
        result = subprocess.run(['bash', str(base / 'new')], input='1\nLiving Room\n',
                                env=env, text=True, capture_output=True, timeout=10)
        return base, result

    def test_client_creates_both_profiles_and_shows_qr_then_link(self):
        base, result = self.run_client()
        self.assertEqual(result.returncode, 0, result.stderr)
        conf = next((base / 'client').glob('*/*.conf'))
        self.assertEqual((base / 'qr-input').read_text(), conf.read_text())
        self.assertEqual((base / 'qr-args').read_text(), '-t\nANSIUTF8\n-l\nL\n-m\n4\n')
        self.assertIn('PrivateKey = TEST_PRIVATE_KEY', conf.read_text())
        self.assertTrue(conf.with_suffix('.mobileconfig').exists())
        self.assertTrue((base / 'routes-applied').exists())
        self.assertEqual((base / 'ike-args').read_text().splitlines()[0], 'test')
        self.assertEqual(result.stdout.count('http://192.0.2.10:8080/p1.mobileconfig'), 1)
        self.assertLess(result.stdout.index('COMPACT_QR'), result.stdout.index('Apple TV / IKEv2'))
        self.assertIn('Living Room - [SOCKS5 - UK]', result.stdout)

    def test_qr_failure_keeps_client_and_apple_link(self):
        base, result = self.run_client(qr_status=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('QR unavailable.', result.stderr)
        self.assertIn('http://192.0.2.10:8080/p1.mobileconfig', result.stdout)
        self.assertTrue((base / 'routes-applied').exists())

    def test_apple_failure_reports_details_and_no_success_summary(self):
        base, result = self.run_client(ike_status=6)
        self.assertEqual(result.returncode, 6)
        self.assertIn('Profile error details', result.stderr)
        self.assertIn('Apple profile creation failed (status 6)', result.stderr)
        self.assertNotIn('Client created:', result.stdout)
        self.assertFalse((base / 'qr-input').exists())


if __name__ == '__main__':
    unittest.main()
