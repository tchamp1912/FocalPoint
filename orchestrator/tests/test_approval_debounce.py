from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).parents[2]


class ApprovalDebounceTests(unittest.TestCase):
    def run_scenario(
        self, adapter: str, permission: dict, resolved: dict | None,
        env_overrides: dict[str, str] | None = None,
    ) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "calls.log"
            mock_cli = root / "focalpoint"
            mock_cli.write_text(
                '#!/bin/bash\nprintf "%s\\n" "$*" >> "$MOCK_FOCALPOINT_LOG"\n',
                encoding="utf-8",
            )
            mock_cli.chmod(0o755)
            env = os.environ.copy()
            env.update({
                "FOCALPOINT_PATH": str(mock_cli),
                "MOCK_FOCALPOINT_LOG": str(log),
                "XDG_STATE_HOME": str(root / "state"),
                "FOCALPOINT_APPROVAL_GRACE_SECS": "0.5",
            })
            env.update(env_overrides or {})
            env.pop("TMUX", None)
            env.pop("TMUX_PANE", None)
            script = ROOT / adapter
            subprocess.run(
                ["bash", str(script)], input=json.dumps(permission), text=True,
                env=env, check=True, timeout=3,
            )
            if resolved is not None:
                time.sleep(0.04)
                subprocess.run(
                    ["bash", str(script)], input=json.dumps(resolved), text=True,
                    env=env, check=True, timeout=3,
                )
            time.sleep(0.9)
            return log.read_text(encoding="utf-8").splitlines() if log.exists() else []

    def test_codex_auto_approval_cancels_waiting(self) -> None:
        common = {"session_id": "codex-1", "cwd": "/tmp/project"}
        calls = self.run_scenario(
            "adapters/codex-cli/hooks.sh",
            {**common, "hook_event_name": "PermissionRequest"},
            {**common, "hook_event_name": "PreToolUse"},
        )
        self.assertTrue(any(line.startswith("set-state running") for line in calls))
        self.assertFalse(any(line.startswith("set-state waiting") for line in calls))

    def test_codex_failed_auto_approval_becomes_waiting(self) -> None:
        calls = self.run_scenario(
            "adapters/codex-cli/hooks.sh",
            {"hook_event_name": "PermissionRequest", "session_id": "codex-2", "cwd": "/tmp"},
            None,
        )
        self.assertTrue(any(line.startswith("set-state waiting") for line in calls))

    def test_claude_auto_approval_cancels_waiting(self) -> None:
        common = {"session_id": "claude-1", "cwd": "/tmp/project"}
        calls = self.run_scenario(
            "adapters/claude-code/hooks.sh",
            {**common, "hook_event_name": "Notification", "notification_type": "permission_prompt"},
            {**common, "hook_event_name": "PreToolUse"},
        )
        self.assertTrue(any(line.startswith("set-state running") for line in calls))
        self.assertFalse(any(line.startswith("set-state waiting") for line in calls))

    def test_claude_failed_auto_approval_becomes_approval(self) -> None:
        calls = self.run_scenario(
            "adapters/claude-code/hooks.sh",
            {"hook_event_name": "Notification", "notification_type": "permission_prompt",
             "session_id": "claude-2", "cwd": "/tmp"},
            None,
        )
        self.assertTrue(any(line.startswith("set-state approval") for line in calls))

    def test_codex_registering_state_carries_relaunch_and_managed_meta(self) -> None:
        calls = self.run_scenario(
            "adapters/codex-cli/hooks.sh",
            {"hook_event_name": "UserPromptSubmit", "session_id": "codex-relaunch",
             "cwd": "/tmp/project", "prompt": "continue"},
            None,
            {"FOCALPOINT_RELAUNCH_ID": "handoff-123"},
        )
        state_call = next(line for line in calls if line.startswith("set-state thinking"))
        self.assertIn("--meta managed=false", state_call)
        self.assertIn("--meta mux_pane=", state_call)
        self.assertIn("--meta relaunch_id=handoff-123", state_call)

    def test_codex_history_resume_carries_exact_session_identity(self) -> None:
        calls = self.run_scenario(
            "adapters/codex-cli/hooks.sh",
            {"hook_event_name": "UserPromptSubmit", "session_id": "codex-session-3",
             "cwd": "/tmp/project", "prompt": "continue"},
            None,
            {"FOCALPOINT_RESUME_SESSION_ID": "codex-session-3"},
        )
        state_call = next(line for line in calls if line.startswith("set-state thinking"))
        self.assertIn("--meta resume_session_id=codex-session-3", state_call)

    def test_claude_deferred_wait_carries_relaunch_and_managed_meta(self) -> None:
        calls = self.run_scenario(
            "adapters/claude-code/hooks.sh",
            {"hook_event_name": "Notification", "notification_type": "permission_prompt",
             "session_id": "claude-relaunch", "cwd": "/tmp/project"},
            None,
            {"FOCALPOINT_RELAUNCH_ID": "handoff-456"},
        )
        state_call = next(line for line in calls if line.startswith("set-state approval"))
        self.assertIn("--meta managed=false", state_call)
        self.assertIn("--meta mux_pane=", state_call)
        self.assertIn("--meta relaunch_id=handoff-456", state_call)

    def test_claude_precompact_carries_relaunch_meta(self) -> None:
        calls = self.run_scenario(
            "adapters/claude-code/hooks.sh",
            {"hook_event_name": "PreCompact", "session_id": "claude-compact",
             "cwd": "/tmp/project"},
            None,
            {"FOCALPOINT_RELAUNCH_ID": "handoff-789"},
        )
        state_call = next(line for line in calls if line.startswith("set-state compacting"))
        self.assertIn("--meta relaunch_id=handoff-789", state_call)

    def test_claude_history_resume_carries_exact_session_identity(self) -> None:
        calls = self.run_scenario(
            "adapters/claude-code/hooks.sh",
            {"hook_event_name": "UserPromptSubmit", "session_id": "claude-session-3",
             "cwd": "/tmp/project"},
            None,
            {"FOCALPOINT_RESUME_SESSION_ID": "claude-session-3"},
        )
        state_call = next(line for line in calls if line.startswith("set-state thinking"))
        self.assertIn("--meta resume_session_id=claude-session-3", state_call)

    def test_claude_history_resume_registers_idle_on_session_start(self) -> None:
        calls = self.run_scenario(
            "adapters/claude-code/hooks.sh",
            {"hook_event_name": "SessionStart", "session_id": "claude-session-4",
             "cwd": "/tmp/project"},
            None,
            {"FOCALPOINT_RESUME_SESSION_ID": "claude-session-4"},
        )
        state_call = next(line for line in calls if line.startswith("set-state idle"))
        self.assertIn("--session claude-session-4", state_call)
        self.assertIn("--refresh-identity", state_call)
        self.assertIn("--meta resume_session_id=claude-session-4", state_call)
        self.assertIn("--meta managed=false", state_call)

    def test_claude_ordinary_session_start_remains_metadata_only(self) -> None:
        calls = self.run_scenario(
            "adapters/claude-code/hooks.sh",
            {"hook_event_name": "SessionStart", "session_id": "claude-fresh",
             "cwd": "/tmp/project"},
            None,
        )
        self.assertTrue(any(line.startswith("set-meta --session claude-fresh") for line in calls))
        self.assertFalse(any(line.startswith("set-state ") for line in calls))


if __name__ == "__main__":
    unittest.main()
