#!/usr/bin/env python3
"""Saved clients with one independent WireGuard/IKEv2 profile per proxy exit."""
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


class ClientManager:
    def __init__(self, base=Path('/Wireguard'), lib=Path('/usr/local/lib/wireguard-proxy'),
                 wg_conf=Path('/etc/wireguard/wg0.conf'),
                 ike_dir=Path('/etc/ipsec.d/clients'),
                 public=Path('/var/lib/wireguard-proxy-public')):
        self.base, self.lib, self.wg_conf = Path(base), Path(lib), Path(wg_conf)
        self.ike_dir, self.public = Path(ike_dir), Path(public)
        self.maps = self.base / 'maps'
        self.registry = self.maps / 'clients.json'
        self.names = []

    def rows(self, filename):
        path = self.maps / filename
        return [line.split('|') for line in path.read_text().splitlines() if line] if path.exists() else []

    @staticmethod
    def safe_component(name):
        return isinstance(name, str) and bool(name) and name not in ('.', '..') and not any(c in name for c in '/\\|\n\r\0')

    @staticmethod
    def validate_name(name):
        if not name or len(name) > 64 or not name.isprintable() or any(c in name for c in '/\\|'):
            raise ValueError('Use 1 to 64 printable characters, without slash, backslash or |, for the client name.')
        return name

    def canonical(self, name):
        return next((n for n in self.names if n.casefold() == name.casefold()), name)

    def save(self):
        temporary = self.registry.with_suffix('.tmp')
        temporary.write_text(json.dumps({'version': 1, 'clients': self.names}, indent=2) + '\n')
        temporary.chmod(0o600)
        temporary.replace(self.registry)

    def load(self):
        if self.registry.exists():
            data = json.loads(self.registry.read_text())
            if not isinstance(data, dict) or data.get('version') != 1 or not isinstance(data.get('clients'), list):
                raise ValueError('Unrecognized client registry. Restore clients.json from backup.')
            self.names = data['clients']
            if not all(isinstance(n, str) and n for n in self.names):
                raise ValueError('Invalid client registry. Restore clients.json from backup.')
        for profile in self.profiles():
            name = self.canonical(profile['client'])
            if name not in self.names:
                self.names.append(name)
        self.save()

    def exits(self):
        return {r[0]: r[2] for r in self.rows('exits.db')
                if len(r) >= 3 and self.safe_component(r[0])
                and (self.base / 'exits' / (r[0] + '.env')).is_file()}

    def profiles(self):
        # Legacy map names are imported in place, without regenerating keys or files.
        found = {}
        for row in self.rows('client_map.db'):
            if len(row) < 3 or not self.safe_component(row[2]):
                continue
            final = row[2]
            match = re.fullmatch(r'(.*) - \[.*\](?:-\d+)?', final)
            name = match[1] if match else final
            found[final] = {'final': final, 'client': name, 'exit': row[1]}
        folder = self.base / 'client'
        if folder.exists():
            for meta in sorted(folder.glob('*/.client-info.json')):
                if meta.parent.is_symlink() or not self.safe_component(meta.parent.name):
                    continue
                info = json.loads(meta.read_text())
                if not isinstance(info, dict) or not isinstance(info.get('client'), str) or not self.safe_component(info.get('exit', '')):
                    raise ValueError('Invalid profile metadata: ' + str(meta))
                found[meta.parent.name] = dict(final=meta.parent.name, client=info['client'], exit=info['exit'])
        for profile in found.values():
            profile['client'] = self.canonical(profile['client'])
        return list(found.values())

    def directory(self, profile):
        return self.base / 'client' / profile['final']

    def ike_row(self, profile):
        return next((r for r in self.rows('ikev2_map.db') if len(r) >= 5
                     and r[1] == profile['exit'] and r[2] == profile['final']), None)

    def ready(self, profile):
        final = profile['final']
        directory = self.directory(profile)
        files = (directory / (final + '.conf'), directory / (final + '.mobileconfig'))
        return (all(p.is_file() and p.stat().st_size for p in files)
                and any(len(r) >= 3 and r[1:3] == [profile['exit'], final] for r in self.rows('client_map.db'))
                and any(len(r) >= 3 and r[1] == final for r in self.rows('peers.db'))
                and self.ike_row(profile) is not None)

    def free_slots(self, filename, subnet):
        used = set()
        network = ipaddress.ip_network(subnet)
        for row in self.rows(filename):
            try:
                address = ipaddress.ip_address(row[0])
            except ValueError:
                continue
            if address in network and 2 <= int(str(address).split('.')[-1]) <= 254:
                used.add(address)
        return 253 - len(used)

    def sync(self, names, slugs, batch=True):
        available = self.exits()
        for slug in slugs:
            if slug not in available:
                raise ValueError('Proxy exit not found: ' + slug)
        if not names:
            print('No saved clients yet. Use helper > Create a client; future proxies will include it.')
            return 0
        if not slugs:
            print('No proxy exits yet. Clients are saved; adding a proxy will generate their profiles.')
            return 0
        current = self.profiles()
        plan, skipped = [], 0
        for name in names:
            self.validate_name(name)
            for slug in slugs:
                matches = [p for p in current if p['client'] == name and p['exit'] == slug]
                if any(self.ready(p) for p in matches):
                    skipped += 1
                else:
                    plan.append((name, slug, matches[0] if matches else None))
        # Count pending WireGuard and IKEv2 allocations separately before starting a bulk sync.
        for filename, subnet, kind in (('client_map.db', '10.8.0.0/24', 'WireGuard'),
                                        ('ikev2_map.db', '10.9.0.0/24', 'IKEv2')):
            rows = self.rows(filename)
            needed = sum(1 for _, slug, p in plan if p is None or not any(
                len(r) >= 3 and r[1:3] == [slug, p['final']] for r in rows))
            free = self.free_slots(filename, subnet)
            if needed > free:
                raise ValueError(f'{kind} address capacity: need {needed} new addresses, only {free} free.')
        failed = 0
        for name, slug, profile in plan:
            print(f'\nCreating: {name} / {available[slug]}', flush=True)
            command = [str(self.lib / 'create-profile'), slug, name,
                       profile['final'] if profile else '', '--batch' if batch else '']
            result = subprocess.run(command)
            self.load()
            complete = any(p['client'] == name and p['exit'] == slug and self.ready(p) for p in self.profiles())
            if result.returncode or not complete:
                failed += 1
                print(f'Failed: {name} / {available[slug]}. Run Manage > Sync missing profiles to retry.', file=sys.stderr)
        route_failed = False
        if any(self.ready(p) for p in self.profiles()):
            route_failed = subprocess.run([str(self.lib / 'apply-routing')]).returncode != 0
            if route_failed:
                print('Route application failed. Run Manage > Sync missing profiles to retry.', file=sys.stderr)
        print(f'\nProfiles: {len(plan) - failed} created/recovered, {skipped} already present, {failed} failed.')
        if not batch and not plan and current:
            matches = [p for p in current if p['client'] in names and p['exit'] in slugs and self.ready(p)]
            if matches:
                self.show_profile(matches[0])
        if batch:
            print('View a QR and Apple TV link: helper > Manage > Show saved profiles.')
        return 1 if failed or route_failed else 0

    @staticmethod
    def choose(options, prompt):
        for i, text in enumerate(options, 1):
            print(f'  [{i}] {text}')
        value = input(prompt).strip()
        if not value.isdecimal() or not 1 <= int(value) <= len(options):
            raise ValueError('Invalid selection.')
        return int(value) - 1

    def new(self, slug=None):
        if slug and slug not in self.exits():
            raise ValueError('Proxy exit not found: ' + slug)
        name = self.validate_name(input('Client name: ').strip())
        name = self.canonical(name)
        if name not in self.names:
            self.names.append(name)
            self.save()
        exits = self.exits()
        if not exits:
            print('Client saved: ' + name)
            return self.sync([name], [])
        if slug:
            return self.sync([name], [slug], batch=False)
        print('\nProxy exits:\n  [0] All proxies (default)')
        for i, label in enumerate(exits.values(), 1):
            print(f'  [{i}] {label}')
        choice = input('Select proxy [0]: ').strip() or '0'
        if not choice.isdecimal() or not 0 <= int(choice) <= len(exits):
            raise ValueError('Invalid proxy selection. Client is saved; retry new with the same name.')
        selected = list(exits) if int(choice) == 0 else [list(exits)[int(choice) - 1]]
        return self.sync([name], selected, batch=len(selected) > 1)

    def show_profile(self, profile):
        final = profile['final']
        conf = self.directory(profile) / (final + '.conf')
        if not conf.is_file():
            raise ValueError('WireGuard config missing: ' + str(conf))
        print('\n' + final + '\nWireGuard config: ' + str(conf), flush=True)
        if shutil.which('qrencode'):
            with conf.open('rb') as stream:
                if subprocess.run(['qrencode', '-t', 'ANSIUTF8', '-l', 'L', '-m', '4'], stdin=stream).returncode:
                    print('QR unavailable. Import the saved config instead.')
        else:
            print('QR unavailable. Install it with: sudo apt-get install -y qrencode')
        row = self.ike_row(profile)
        mobile = self.directory(profile) / (final + '.mobileconfig')
        if row and self.safe_component(row[4]) and mobile.is_file():
            self.public.mkdir(parents=True, exist_ok=True)
            self.public.chmod(0o755)
            published = self.public / row[4]
            if not published.exists():
                shutil.copyfile(mobile, published)
                published.chmod(0o644)
            subprocess.run(['systemctl', 'start', 'wg-http'], check=True)
            server = (self.base / 'ikev2/server/server_id').read_text().strip()
            print(f'\nApple TV / IKEv2 profile:\n  http://{server}:8080/{row[4]}')
        else:
            print('Apple profile incomplete. Run Manage > Sync missing profiles.')

    def show(self):
        if not self.names:
            print('No saved clients.')
            return 0
        name = self.names[self.choose(self.names, 'Select client: ')]
        profiles = [p for p in self.profiles() if p['client'] == name]
        if not profiles:
            print('No profiles for this client yet. Add a proxy or sync missing profiles.')
            return 0
        profile = profiles[self.choose([p['final'] for p in profiles], 'Select profile: ')]
        self.show_profile(profile)
        return 0

    def remove(self):
        if not self.names:
            print('No saved clients.')
            return 0
        name = self.names[self.choose(self.names, 'Select client to remove: ')]
        profiles = [p for p in self.profiles() if p['client'] == name]
        if input(f'Remove {name} and all {len(profiles)} profiles? [y/N]: ').lower() != 'y':
            print('Cancelled.')
            return 0
        finals = {p['final'] for p in profiles}
        peers = self.rows('peers.db')
        keys = {r[0] for r in peers if len(r) >= 3 and r[1] in finals}
        text = self.wg_conf.read_text()
        sections = re.split(r'(?=^\[Peer\]\s*$)', text, flags=re.M)
        kept = []
        for section in sections:
            pub = re.search(r'^PublicKey\s*=\s*(\S+)\s*$', section, re.M)
            label = re.search(r'^# (.+)$', section, re.M)
            belongs = (pub and pub[1] in keys) or (label and label[1] in finals)
            if not (section.startswith('[Peer]') and belongs):
                kept.append(section)
        self.wg_conf.write_text(''.join(kept))
        self.wg_conf.chmod(0o600)
        ike_rows = [r for r in self.rows('ikev2_map.db') if len(r) >= 5 and r[2] in finals]
        for filename, index in (('client_map.db', 2), ('peers.db', 1), ('ikev2_map.db', 2)):
            rows = [r for r in self.rows(filename) if len(r) <= index or r[index] not in finals]
            path = self.maps / filename
            path.write_text(''.join('|'.join(r) + '\n' for r in rows))
            path.chmod(0o600)
        for row in ike_rows:
            if self.safe_component(row[3]):
                (self.ike_dir / (row[3] + '.conf')).unlink(missing_ok=True)
            if self.safe_component(row[4]):
                (self.public / row[4]).unlink(missing_ok=True)
        for profile in profiles:
            directory = self.directory(profile)
            if directory.exists() and not directory.is_symlink():
                shutil.rmtree(directory)
        self.names.remove(name)
        self.save()
        # Apply the reduced peer list without disconnecting unrelated WireGuard clients.
        stripped = subprocess.run(['wg-quick', 'strip', 'wg0'], capture_output=True, check=True)
        import tempfile
        with tempfile.NamedTemporaryFile() as configuration:
            configuration.write(stripped.stdout)
            configuration.flush()
            subprocess.run(['wg', 'syncconf', 'wg0', configuration.name], check=True)
        result = subprocess.run(['systemctl', 'restart', 'strongswan-starter'])
        if result.returncode:
            subprocess.run(['systemctl', 'restart', 'strongswan'], check=True)
        subprocess.run([str(self.lib / 'apply-routing')], check=True)
        print('Removed client and all profiles: ' + name)
        return 0


def main():
    if os.geteuid() != 0:
        sys.exit('Run this command through helper or with sudo.')
    os.umask(0o077)
    manager = ClientManager()
    manager.maps.mkdir(parents=True, exist_ok=True)
    with (manager.maps / 'client-manager.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manager.load()
        command = sys.argv[1] if len(sys.argv) > 1 else 'new'
        if command == 'new':
            return manager.new(sys.argv[2] if len(sys.argv) > 2 else None)
        if command == 'sync-exit' and len(sys.argv) == 3:
            return manager.sync(manager.names[:], [sys.argv[2]])
        if command == 'sync':
            return manager.sync(manager.names[:], list(manager.exits()))
        if command == 'show':
            return manager.show()
        if command == 'remove':
            return manager.remove()
        if command == 'migrate':
            print(f'Imported {len(manager.names)} saved clients. Existing profile files are unchanged.')
            return 0
        raise ValueError('Unknown client-manager command.')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
    except (EOFError, KeyboardInterrupt):
        sys.exit('\nCancelled.')
