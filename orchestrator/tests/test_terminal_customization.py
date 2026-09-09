from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parents[2]


class TerminalCustomizationTests(unittest.TestCase):
    def launch(self, color, custom_launcher=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tmux = root / 'tmux'
            tmux.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
            tmux.chmod(0o755)
            env = dict(os.environ, FOCALPOINT_TMUX_BIN=str(tmux),
                       FOCALPOINT_TERMINAL_COLOR=color, XDG_STATE_HOME=str(root))
            if custom_launcher:
                env['FOCALPOINT_CUSTOM_LAUNCHER'] = custom_launcher
            else:
                env.pop('FOCALPOINT_CUSTOM_LAUNCHER', None)
            env.pop('TMUX', None)
            return subprocess.run(['bash', str(ROOT / 'orchestrator/focalpoint-run.sh'),
                                   'codex', 'a task with spaces'], env=env,
                                  capture_output=True, text=True, timeout=5)

    def test_accent_is_applied_after_creation_without_changing_provider_arguments(self):
        result = self.launch('#6C8CFF')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)
        self.assertIn('FOCALPOINT_TERMINAL_COLOR=#6C8CFF', args)
        command = args.index('codex')
        self.assertEqual(args[command:command + 4], ['codex', 'a task with spaces', ';', 'bind-key'] if Path('/usr/bin/pbcopy').exists() else ['codex', 'a task with spaces', ';', 'set-option'])
        self.assertIn('bg=#6C8CFF,fg=#111111', args)
        self.assertNotIn('window-style', args)

    def test_custom_launcher_identity_is_forwarded_to_the_private_pane(self):
        result = self.launch('', '/tmp/work launcher.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('FOCALPOINT_CUSTOM_LAUNCHER=/tmp/work launcher.sh', json.loads(result.stdout))

    def test_default_has_no_accent_commands(self):
        result = self.launch('')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('status-style', json.loads(result.stdout))

    @unittest.skipUnless(Path('/usr/bin/pbcopy').exists(), 'macOS clipboard')
    def test_copy_bindings_upgrade_existing_configs_without_disabling_mouse(self):
        result = self.launch('')
        args = json.loads(result.stdout)
        self.assertIn('MouseDragEnd1Pane', args)
        self.assertIn('copy-pipe-and-cancel', args)
        self.assertIn('/usr/bin/pbcopy', args)
        self.assertNotIn('mouse', args)

    def test_style_injection_is_rejected_before_tmux_starts(self):
        result = self.launch('#ffffff;run-shell touch /tmp/unwanted')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('six-digit hex color', result.stderr)


if __name__ == '__main__':
    unittest.main()
