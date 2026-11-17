"""Integration checks using the real profile scripts and isolated fake VPN tools."""
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('client_manager', ROOT / 'client-manager.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

FAKE_TOOLS = '''#!/usr/bin/env python3
import base64, hashlib, os, sys, uuid
from pathlib import Path
base = Path(os.environ['TEST_BASE'])
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
if tool == 'curl':
    print('192.0.2.10')
elif tool == 'wg':
    if args[0] == 'genkey':
        counter = base / 'keys-generated'
        count = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(count))
        print(base64.b64encode(count.to_bytes(32, 'big')).decode())
    elif args[0] == 'pubkey':
        print(base64.b64encode(hashlib.sha256(sys.stdin.buffer.read()).digest()).decode())
elif tool == 'wg-quick':
    print((base / 'wg0.conf').read_text())
elif tool == 'ipsec':
    if '--issue' in args:
        sys.stdin.buffer.read()
    if (base / 'fail-ike').exists():
        print('PKI failed for test', file=sys.stderr)
        sys.exit(6)
    print('FAKE_CERTIFICATE_OR_KEY')
elif tool == 'openssl':
    if args[0] == 'rand':
        print('FAKE_PASSWORD')
    elif args[0] == 'pkcs12':
        Path(args[args.index('-out') + 1]).write_text('FAKE_P12')
    elif args[0] == 'x509':
        print('FAKE_CA')
elif tool == 'uuidgen':
    print(uuid.uuid4())
elif tool == 'systemctl':
    with (base / 'service-calls').open('a') as stream:
        stream.write(' '.join(args) + '\\n')
elif tool == 'qrencode':
    (base / 'qr-input').write_bytes(sys.stdin.buffer.read())
    (base / 'qr-args').write_text(' '.join(args))
    print('COMPACT_QR')
    if (base / 'fail-qr').exists():
        sys.exit(5)
elif tool == 'jq':
    print('{}')
'''


class NewClientTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        b = self.base
        for directory in ('maps', 'exits', 'client', 'server', 'ikev2/server', 'ikev2/ca',
                          'ike-conf', 'public', 'lib', 'bin', 'proxies'):
            (b / directory).mkdir(parents=True)
        for filename in ('client_map.db', 'peers.db', 'ikev2_map.db', 'exits.db'):
            (b / 'maps' / filename).touch()
        (b / 'server/server_publickey').write_text('SERVER_PUBLIC_KEY\n')
        (b / 'ikev2/server/server_id').write_text('192.0.2.10\n')
        (b / 'ikev2/ca/caCert.pem').write_text('FAKE_CA\n')
        (b / 'ikev2/ca/caKey.pem').write_text('FAKE_CA_PRIVATE\n')
        (b / 'wg0.conf').write_text('[Interface]\nAddress = 10.8.0.1/24\n')
        (b / 'bin/fake-tool').write_text(FAKE_TOOLS)
        (b / 'bin/fake-tool').chmod(0o755)
        for tool in ('curl', 'wg', 'wg-quick', 'ipsec', 'openssl', 'uuidgen', 'systemctl', 'qrencode', 'jq'):
            (b / 'bin' / tool).symlink_to('fake-tool')
        for source, target in (('create-profile.sh', 'create-profile'), ('ikev2-profile.sh', 'new-ikev2-profile')):
            script = self.relocate((ROOT / source).read_text())
            (b / 'lib' / target).write_text(script)
            (b / 'lib' / target).chmod(0o755)
        (b / 'lib/apply-routing').write_text('#!/bin/bash\n[ ! -f "$TEST_BASE/fail-routes" ] || exit 9\necho applied >> "$TEST_BASE/routes-applied"\n')
        (b / 'lib/apply-routing').chmod(0o755)
        self.manager = module.ClientManager(b, b / 'lib', b / 'wg0.conf', b / 'ike-conf', b / 'public')
        self.env = patch.dict(os.environ, TEST_BASE=str(b), PATH=str(b / 'bin') + ':' + os.environ['PATH'])
        self.env.start()
        self.addCleanup(self.env.stop)
        self.manager.load()

    def relocate(self, script):
        return (script.replace('/Wireguard', str(self.base))
                .replace('/etc/wireguard/wg0.conf', str(self.base / 'wg0.conf'))
                .replace('/usr/local/lib/wireguard-proxy/', str(self.base / 'lib') + '/')
                .replace('/usr/local/bin/', str(self.base / 'bin') + '/')
                .replace('/etc/ipsec.d/clients', str(self.base / 'ike-conf'))
                .replace('/var/lib/wireguard-proxy-public', str(self.base / 'public')))

    def add_exit(self, slug, label):
        path = self.base / 'exits' / (slug + '.env')
        path.write_text(f'SLUG={slug}\nTYPE_TAG=S5\nLABEL={shlex.quote(label)}\n')
        with (self.base / 'maps/exits.db').open('a') as stream:
            stream.write(f'{slug}|proxy|{label} [S5]|tun1|1001\n')

    def add_client(self, name, selection='0'):
        with patch('builtins.input', side_effect=[name, selection]), redirect_stdout(io.StringIO()):
            return self.manager.new()

    def sync(self, names=None, slugs=None, batch=True):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return self.manager.sync(self.manager.names[:] if names is None else names,
                                     list(self.manager.exits()) if slugs is None else slugs, batch=batch)

    def test_new_country_creates_each_client_without_changing_old_profiles(self):
        self.add_exit('uk', 'UK')
        self.assertEqual(self.add_client('Alice'), 0)
        self.assertEqual(self.add_client('Bob'), 0)
        before = {p: p.read_bytes() for p in (self.base / 'client').glob('*/*') if p.is_file()}
        self.add_exit('france', 'France')
        self.assertEqual(self.sync(slugs=['france']), 0)
        self.assertEqual(len(self.manager.names), 2)
        profiles = self.manager.profiles()
        self.assertEqual(len(profiles), 4)
        self.assertTrue(all(self.manager.ready(p) for p in profiles))
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content)
        for filename in ('client_map.db', 'ikev2_map.db'):
            addresses = [r[0] for r in self.manager.rows(filename)]
            self.assertEqual(len(addresses), len(set(addresses)))
        all_before = {p: p.read_bytes() for p in (self.base / 'client').glob('*/*') if p.is_file()}
        self.assertEqual(self.sync(), 0)
        self.assertEqual(len(self.manager.profiles()), 4)
        self.assertEqual(int((self.base / 'keys-generated').read_text()), 4)
        for path, content in all_before.items():
            self.assertEqual(path.read_bytes(), content)

    def test_client_first_then_proxy_and_new_client_one_or_all(self):
        with patch('builtins.input', return_value='Alice'), redirect_stdout(io.StringIO()):
            self.assertEqual(self.manager.new(), 0)
        self.assertEqual(self.manager.names, ['Alice'])
        self.add_exit('uk', 'UK')
        self.assertEqual(self.sync(), 0)
        self.add_exit('france', 'France')
        self.assertEqual(self.add_client('Bob', '2'), 0)
        self.assertEqual({p['exit'] for p in self.manager.profiles() if p['client'] == 'Bob'}, {'france'})
        self.assertEqual(self.add_client('Charlie'), 0)
        self.assertEqual({p['exit'] for p in self.manager.profiles() if p['client'] == 'Charlie'}, {'uk', 'france'})
        self.assertEqual(self.add_client('CHARLIE'), 0)
        self.assertEqual(len(self.manager.names), 3)

    def test_import_legacy_profiles_groups_countries_without_replacing_keys(self):
        self.add_exit('uk', 'UK')
        self.add_exit('france', 'France')
        self.assertEqual(self.add_client('Alice'), 0)
        before = (self.base / 'wg0.conf').read_bytes()
        for path in (self.base / 'client').glob('*/.client-info.json'):
            path.unlink()
        self.manager.registry.unlink()
        self.manager.names = []
        self.manager.load()
        self.assertEqual(self.manager.names, ['Alice'])
        self.assertEqual(self.sync(), 0)
        self.assertEqual((self.base / 'wg0.conf').read_bytes(), before)
        self.assertEqual(len(self.manager.profiles()), 2)

    def test_apple_failure_retry_reuses_wireguard_and_does_not_duplicate(self):
        self.add_exit('uk', 'UK')
        (self.base / 'fail-ike').touch()
        self.assertEqual(self.add_client('Alice'), 1)
        self.assertEqual(len(self.manager.rows('client_map.db')), 1)
        conf = next((self.base / 'client').glob('*/*.conf'))
        original = conf.read_bytes()
        (self.base / 'fail-ike').unlink()
        self.assertEqual(self.sync(), 0)
        self.assertEqual(conf.read_bytes(), original)
        self.assertEqual(int((self.base / 'keys-generated').read_text()), 1)
        self.assertEqual(len(self.manager.rows('ikev2_map.db')), 1)
        self.assertTrue(self.manager.ready(self.manager.profiles()[0]))

    def test_routes_retry_and_qr_failure_keep_profiles(self):
        self.add_exit('uk', 'UK')
        (self.base / 'fail-routes').touch()
        self.assertEqual(self.add_client('Alice'), 1)
        (self.base / 'fail-routes').unlink()
        self.assertEqual(self.sync(), 0)
        (self.base / 'fail-qr').touch()
        self.assertEqual(self.sync(batch=False), 0)
        profile = self.manager.profiles()[0]
        self.assertTrue(self.manager.ready(profile))
        (self.base / 'public/p1.mobileconfig').unlink()
        with redirect_stdout(io.StringIO()) as output:
            self.manager.show_profile(profile)
        self.assertIn('http://192.0.2.10:8080/p1.mobileconfig', output.getvalue())
        self.assertTrue((self.base / 'public/p1.mobileconfig').exists())
        self.assertEqual((self.base / 'qr-args').read_text(), '-t ANSIUTF8 -l L -m 4')

    def test_profile_labels_and_ike_identities_are_unique(self):
        self.add_exit('uk', 'UK')
        self.add_exit('uk-2', 'UK')
        self.assertEqual(self.add_client('A_B'), 0)
        self.assertEqual(self.add_client('A B'), 0)
        self.assertEqual(self.add_client("O'Connor"), 0)
        self.assertEqual(self.add_client('A&B "Phone"'), 0)
        profiles = self.manager.profiles()
        self.assertEqual(len(profiles), 8)
        usernames = [r[3] for r in self.manager.rows('ikev2_map.db')]
        self.assertEqual(len(set(usernames)), 8)
        for profile in profiles:
            path = self.manager.directory(profile) / (profile['final'] + '.mobileconfig')
            data = plistlib.loads(path.read_bytes())
            self.assertEqual(data['PayloadDisplayName'], profile['final'])

    def test_add_proxy_command_automatically_syncs_saved_clients(self):
        self.add_exit('uk', 'UK')
        self.assertEqual(self.add_client('Alice'), 0)
        self.assertEqual(self.add_client('Bob'), 0)
        script = self.base / 'bin/add'
        script.write_text(self.relocate((ROOT / 'add-proxy.sh').read_text()))
        script.chmod(0o755)
        (self.base / 'bin/sing-box').write_text('#!/bin/bash\nexit 0\n')
        (self.base / 'bin/sing-box').chmod(0o755)
        build = self.base / 'lib/build-routes'
        build.write_text('#!/bin/bash\n: > "$TEST_BASE/maps/exits.db"\n'
                         'for f in "$TEST_BASE"/exits/*.env; do\n'
                         'source "$f"\n'
                         'printf "%s|proxy|%s [%s]|tun|1001\\n" "$SLUG" "$LABEL" "$TYPE_TAG" >> "$TEST_BASE/maps/exits.db"\n'
                         'done\n')
        build.chmod(0o755)
        harness = self.base / 'lib/client-manager'
        harness.write_text('import importlib.util,sys\nfrom pathlib import Path\n'
                           + 's=importlib.util.spec_from_file_location("manager", ' + repr(str(ROOT / 'client-manager.py')) + ')\n'
                           + 'm=importlib.util.module_from_spec(s); s.loader.exec_module(m)\n'
                           + 'b=Path(' + repr(str(self.base)) + ')\n'
                           + 'manager=m.ClientManager(b,b/"lib",b/"wg0.conf",b/"ike-conf",b/"public")\n'
                           + 'manager.load()\nassert sys.argv[1] == "sync-exit"\n'
                           + 'sys.exit(manager.sync(manager.names[:],[sys.argv[2]]))\n')
        result = subprocess.run(['bash', str(script)], input='2\nFrance\n198.51.100.20\n1080\n1\ny\ny\n',
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.manager.load()
        self.assertEqual(len(self.manager.profiles()), 4)
        self.assertEqual(len(self.manager.names), 2)
        self.assertNotIn('Create client?', result.stdout)
        self.assertIn('Exit saved: France', result.stdout)

    def test_capacity_preflight_does_not_create_partial_bulk(self):
        self.add_exit('uk', 'UK')
        self.manager.names = ['Alice', 'Bob']
        self.manager.save()
        (self.base / 'maps/ikev2_map.db').write_text(''.join(f'10.9.0.{i}|unused|reserved|id|profile\n' for i in range(2, 255)))
        with self.assertRaisesRegex(ValueError, 'need 2 new addresses, only 0 free'):
            self.sync()
        self.assertEqual(self.manager.rows('client_map.db'), [])
        self.assertFalse((self.base / 'keys-generated').exists())

    def test_remove_saved_client_removes_all_countries_and_exact_names_only(self):
        self.add_exit('uk', 'UK')
        self.add_exit('france', 'France')
        self.assertEqual(self.add_client('Ann'), 0)
        self.assertEqual(self.add_client('Anna'), 0)
        with patch('builtins.input', side_effect=['1', 'y']), redirect_stdout(io.StringIO()):
            self.assertEqual(self.manager.remove(), 0)
        self.manager.load()
        self.assertEqual(self.manager.names, ['Anna'])
        self.assertEqual(len(self.manager.profiles()), 2)
        self.assertTrue(all(p['client'] == 'Anna' for p in self.manager.profiles()))
        self.assertNotIn('# Ann - [', (self.base / 'wg0.conf').read_text())
        self.assertEqual(len(list((self.base / 'ike-conf').glob('*.conf'))), 2)
        self.assertEqual(len(list((self.base / 'public').glob('*.mobileconfig'))), 2)
        self.add_exit('germany', 'Germany')
        self.assertEqual(self.sync(slugs=['germany']), 0)
        self.assertEqual(len(self.manager.profiles()), 3)

    def test_missing_mapped_config_does_not_regenerate_keys_or_duplicate_peer(self):
        self.add_exit('uk', 'UK')
        self.assertEqual(self.add_client('Alice'), 0)
        profile = self.manager.profiles()[0]
        (self.manager.directory(profile) / (profile['final'] + '.conf')).unlink()
        self.assertEqual(self.sync(), 1)
        self.assertEqual(len(self.manager.rows('client_map.db')), 1)
        self.assertEqual(int((self.base / 'keys-generated').read_text()), 1)

    def test_malformed_registry_stops_instead_of_forgetting_clients(self):
        self.manager.registry.write_text('{broken')
        with self.assertRaises(ValueError):
            self.manager.load()

    def test_unsafe_name_is_rejected_before_profile_changes(self):
        self.add_exit('uk', 'UK')
        for name in ('../Alice', 'Alice|Bob', 'Alice\nBob'):
            with patch('builtins.input', return_value=name), self.assertRaises(ValueError):
                self.manager.new()
        self.assertEqual(self.manager.names, [])
        self.assertFalse((self.base / 'keys-generated').exists())


class PackagingTests(unittest.TestCase):
    def test_fresh_installer_matches_update_tools_and_syntax(self):
        installer = (ROOT / 'install.sh').read_text()
        for marker, filename in (('ADD', 'add-proxy.sh'), ('NEWCLIENT', 'new-client.sh'),
                                 ('CREATEPROFILE', 'create-profile.sh'), ('CLIENTMANAGER', 'client-manager.py'),
                                 ('IKE', 'ikev2-profile.sh'), ('REMOVE', 'remove-client.sh'), ('MANAGE', 'manage.sh')):
            embedded = installer.split("<<'" + marker + "'\n", 1)[1].split('\n' + marker + '\n', 1)[0] + '\n'
            self.assertEqual(embedded, (ROOT / filename).read_text(), filename)
        for path in ROOT.glob('*.sh'):
            subprocess.run(['bash', '-n', str(path)], check=True)


if __name__ == '__main__':
    unittest.main()
