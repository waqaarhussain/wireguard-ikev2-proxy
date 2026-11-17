"""Exercise the launcher with isolated stub tools, never the live VPN tools.

Run with: python3 -m unittest discover -s tests -v
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HelperTests(unittest.TestCase):
    def test_installer_embeds_current_launcher(self):
        installer = (ROOT / 'install.sh').read_text()
        embedded = installer.split("cat >/usr/local/bin/helper <<'HELPER'\n", 1)[1]
        embedded = embedded.split('\nHELPER\n', 1)[0] + '\n'
        self.assertEqual(embedded, (ROOT / 'helper.sh').read_text())

    def test_shell_syntax(self):
        for script in ('helper.sh', 'install.sh'):
            subprocess.run(['bash', '-n', str(ROOT / script)], check=True)

    def test_menu_dispatch_and_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            sudo = base / 'sudo'
            sudo.write_text('#!/bin/bash\necho SUDO\nshift\nexec "$@"\n')
            sudo.chmod(0o755)
            env = dict(os.environ, PATH=str(base) + ':' + os.environ['PATH'])
            source = (ROOT / 'helper.sh').read_text()
            script = base / 'helper'
            script.write_text(source.replace('/usr/local/bin/', str(base) + '/'))
            for tool in ('add', 'new', 'manage', 'bench'):
                stub = base / tool
                stub.write_text('#!/bin/bash\necho CALLED:' + tool + '\n'
                                + ('exit 7\n' if tool == 'new' else 'exit 0\n'))
                stub.chmod(0o755)
            result = subprocess.run(['/bin/bash', str(script)],
                                    input='bad\n99\n1\n2\n3\n4\n0\n',
                                    env=env, text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count('Invalid choice.'), 2)
            for tool in ('add', 'new', 'manage', 'bench'):
                self.assertEqual(result.stdout.count('CALLED:' + tool), 1)
            self.assertIn('new exited with status 7', result.stderr)
            self.assertEqual(result.stdout.count('SUDO'), 0 if os.geteuid() == 0 else 4)
            (base / 'add').unlink()
            result = subprocess.run(['/bin/bash', str(script)], input='1\n3\n',
                                    env=env, text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Missing command:', result.stderr)
            self.assertIn('CALLED:manage', result.stdout)
            self.assertEqual(result.stdout.count('WireGuard / IKEv2 Proxy'), 3)
            for value in ('q\n', 'Q\n', ''):
                result = subprocess.run(['/bin/bash', str(script)], input=value,
                                        env=env, text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0)
                self.assertNotIn('CALLED:', result.stdout)

    @unittest.skipIf(os.geteuid() == 0, 'root does not need sudo')
    def test_missing_sudo_returns_to_menu(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            script = base / 'helper'
            source = (ROOT / 'helper.sh').read_text()
            script.write_text(source.replace('/usr/local/bin/', str(base) + '/'))
            stub = base / 'add'
            stub.write_text('#!/bin/bash\necho SHOULD_NOT_RUN\n')
            stub.chmod(0o755)
            result = subprocess.run(['/bin/bash', str(script)], input='1\n0\n',
                                    env=dict(os.environ, PATH=str(base)),
                                    text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertIn('Root access is required.', result.stderr)
            self.assertNotIn('SHOULD_NOT_RUN', result.stdout)


if __name__ == '__main__':
    unittest.main()
