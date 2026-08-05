from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
from typing import Optional
import unittest


ROOT = Path(__file__).parents[2]
RUNNER = ROOT / "orchestrator" / "focalpoint-run.sh"


class ManagedResumeIdentityTests(unittest.TestCase):
    def run_wrapper(self, *command: str, task_id: Optional[str] = None,
                    role: Optional[str] = None, manager_task_id: Optional[str] = None,
                    title: Optional[str] = None, slot: Optional[str] = None) -> str:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_tmux = root / "tmux"
            fake_tmux.write_text(
                '#!/bin/bash\nresume=""\ntask=""\nrole=""\nmanager=""\ntitle=""\nslot=""\n'
                'for arg in "$@"; do\n'
                '  case "$arg" in\n'
                '    FOCALPOINT_RESUME_SESSION_ID=*) resume="${arg#*=}" ;;\n'
                '    FOCALPOINT_ORCHESTRATOR_TASK_ID=*) task="${arg#*=}" ;;\n'
                '    FOCALPOINT_ORCHESTRATION_ROLE=*) role="${arg#*=}" ;;\n'
                '    FOCALPOINT_MANAGER_TASK_ID=*) manager="${arg#*=}" ;;\n'
                '    FOCALPOINT_SESSION_TITLE=*) title="${arg#*=}" ;;\n'
                '    FOCALPOINT_SESSION_SLOT=*) slot="${arg#*=}" ;;\n'
                '  esac\n'
                'done\nprintf "%s|%s|%s|%s|%s|%s" "$resume" "$task" "$role" "$manager" "$title" "$slot"\n',
                encoding="utf-8",
            )
            fake_tmux.chmod(0o755)
            env = os.environ.copy()
            env.update({
                "HOME": str(root),
                "FOCALPOINT_TMUX_BIN": str(fake_tmux),
            })
            env.pop("TMUX", None)
            env.pop("FOCALPOINT_RESUME_SESSION_ID", None)
            if task_id is None:
                env.pop("FOCALPOINT_ORCHESTRATOR_TASK_ID", None)
            else:
                env["FOCALPOINT_ORCHESTRATOR_TASK_ID"] = task_id
            for key, value in [
                ("FOCALPOINT_ORCHESTRATION_ROLE", role),
                ("FOCALPOINT_MANAGER_TASK_ID", manager_task_id),
                ("FOCALPOINT_SESSION_TITLE", title),
                ("FOCALPOINT_SESSION_SLOT", slot),
            ]:
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value
            result = subprocess.run(
                ["bash", str(RUNNER), *command],
                text=True,
                capture_output=True,
                env=env,
                check=True,
                timeout=3,
            )
            return result.stdout

    def test_codex_resume_exports_exact_conversation_id(self) -> None:
        self.assertEqual(
            self.run_wrapper("codex", "resume", "codex-session-3"),
            "codex-session-3|||||",
        )

    def test_claude_resume_exports_exact_conversation_id(self) -> None:
        self.assertEqual(
            self.run_wrapper("claude", "--resume", "claude-session-3"),
            "claude-session-3|||||",
        )

    def test_normal_launch_has_no_resume_identity(self) -> None:
        self.assertEqual(self.run_wrapper("codex"), "|||||")

    def test_orchestrator_task_id_is_passed_to_new_tmux_session(self) -> None:
        self.assertEqual(self.run_wrapper("claude", task_id="task-3"), "|task-3||||")

    def test_orchestration_relationship_is_passed_to_new_tmux_session(self) -> None:
        self.assertEqual(
            self.run_wrapper("codex", task_id="worker-1", role="worker",
                             manager_task_id="orchestrator-1"),
            "|worker-1|worker|orchestrator-1||",
        )

    def test_number_and_title_are_passed_to_new_tmux_session(self) -> None:
        self.assertEqual(
            self.run_wrapper("codex", task_id="worker-2", role="worker",
                             title="Parser implementation", slot="4"),
            "|worker-2|worker||Parser implementation|4",
        )


if __name__ == "__main__":
    unittest.main()
