#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ADAPTER = Path(__file__).resolve().parents[1]

class GeminiAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="focalpoint-gemini-")
        self.root = Path(self.temp.name)
        self.log = self.root / "calls.jsonl"
        fp = self.root / "focalpoint"
        fp.write_text('#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["TEST_CALLS"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n')
        fp.chmod(0o755)
        self.env = dict(os.environ, FOCALPOINT_PATH=str(fp), TEST_CALLS=str(self.log), PATH=str(self.root)+os.pathsep+os.environ["PATH"])
        for key in list(self.env):
            if key.startswith("FOCALPOINT_") and key != "FOCALPOINT_PATH": self.env.pop(key)
        self.env.pop("TMUX", None)

    def tearDown(self): self.temp.cleanup()

    def hook(self, event, **extra):
        payload = dict(session_id="gemini-123", cwd="/tmp/project", hook_event_name=event, **extra)
        result = subprocess.run([str(ADAPTER / "hooks.sh")], input=json.dumps(payload), text=True, capture_output=True, env=self.env, check=True)
        self.assertEqual(json.loads(result.stdout), {})
        return self.calls()

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_lifecycle_and_states(self):
        for event,state in [("SessionStart","idle"),("BeforeAgent","thinking"),("BeforeTool","running"),("AfterTool","thinking"),("AfterAgent","done")]:
            call=self.hook(event)[-1]
            self.assertEqual(call[:2],["set-state",state])
            self.assertEqual(call[call.index("--kind")+1],"gemini")
            self.assertIn("managed=false",call)
        self.assertIn("--refresh-identity",self.calls()[0])
        self.assertEqual(self.hook("SessionEnd")[-1],["end-session","gemini-123"])

    def test_permission_is_exact_and_tool_failure(self):
        self.hook("Notification",notification_type="permission_prompt")
        self.assertEqual(self.calls(),[])
        self.assertEqual(self.hook("Notification",notification_type="ToolPermission")[-1][1],"approval")
        self.assertEqual(self.hook("AfterTool",tool_response={"error":"failed"})[-1][1],"error")

    def test_model_hooks_do_not_overwrite_parent_for_subagents(self):
        self.hook("BeforeModel",llm_request={"model":"child-model","messages":[{"content":"PRIVATE PROMPT"}]})
        self.hook("PreCompress",trigger="auto")
        self.assertEqual(self.calls(),[])

    def test_managed_metadata(self):
        tmux=self.root/"tmux"
        tmux.write_text('#!/bin/bash\n[ \"$5\" = \"-t\" ] && [ \"$6\" = \"%7\" ] || exit 9\ncase "${!#}" in "#{pane_id}") echo %7;; "#{session_name}") echo agent;; esac\n')
        tmux.chmod(0o755)
        self.env.update(TMUX="/tmp/private.sock,42,0",TMUX_PANE="%7",FOCALPOINT_TMUX_SERVER="focalpoint-test",FOCALPOINT_LAUNCH_ID="launch-1",FOCALPOINT_ORCHESTRATOR_TASK_ID="task-1",FOCALPOINT_SESSION_TITLE="Managed Gemini")
        call=self.hook("SessionStart")[-1]
        for value in ["managed=true","mux_pane=%7","mux_session=agent","mux_server=focalpoint-test","mux_socket=/tmp/private.sock","launch_id=launch-1","orchestrator_task_id=task-1"]: self.assertIn(value,call)

    def test_invalid_payloads_do_nothing(self):
        for payload in ["not json", "[]", json.dumps({"hook_event_name":"SessionEnd","session_id":"--bad"})]:
            result=subprocess.run([str(ADAPTER/"hooks.sh")],input=payload,text=True,capture_output=True,env=self.env,check=True)
            self.assertEqual(json.loads(result.stdout),{})
        self.assertEqual(self.calls(),[])

    def test_merge_preserves_user_hooks_and_quotes_paths(self):
        settings=self.root/"settings.json"
        original={"theme":"dark","hooks":{"disabled":["my-disabled-hook"],"BeforeTool":[{"matcher":"read_file","sequential":True,"hooks":[{"type":"command","name":"my-hook","command":"echo custom"},{"type":"command","name":"focalpoint-gemini-BeforeTool","command":"old/path"}]}]}}
        settings.write_text(json.dumps(original))
        command="/tmp/folder with ' quotes/$literal/gemini-hooks.sh"
        args=[str(ADAPTER/"merge-hooks.sh"),str(settings),str(ADAPTER/"settings-fragment.json"),command]
        first=json.loads(subprocess.check_output(args,text=True))
        self.assertEqual(first["theme"],"dark")
        self.assertEqual(first["hooks"]["disabled"],["my-disabled-hook"])
        group=first["hooks"]["BeforeTool"][0]
        self.assertTrue(group["sequential"])
        self.assertEqual(group["hooks"],[original["hooks"]["BeforeTool"][0]["hooks"][0]])
        for groups in first["hooks"].values():
            for group in groups:
                if not isinstance(group,dict): continue
                for hook in group["hooks"]:
                    if hook.get("name","").startswith("focalpoint-gemini-"):
                        self.assertEqual(shlex.split(hook["command"]),[command])
        settings.write_text(json.dumps(first))
        second=json.loads(subprocess.check_output(args,text=True))
        self.assertEqual(first,second)

    def test_commented_settings_disabled_configuration_and_obsolete_hooks(self):
        settings=self.root/"settings.json"
        settings.write_text('''{
          // Keep authentication and custom settings untouched.
          "endpoint": "https://example.test/path//segment", /* inline block */
          "literal": "/* text, not a comment */ and \\"quoted\\"",
          "hooksConfig": {"enabled": false, "disabled": ["focalpoint-gemini-SessionStart"]},
          "hooks": {
            "BeforeModel": [{"hooks": [
              {"name": "focalpoint-gemini-BeforeModel", "type": "command", "command": "old"},
              {"name": "user-model-hook", "type": "command", "command": "echo user"}
            ]}],
            "PreCompress": [{"hooks": [{"name":"focalpoint-gemini-PreCompress", "command":"old", "type":"command"}]}]
          }
        }''')
        args=[str(ADAPTER/"merge-hooks.sh"),str(settings),str(ADAPTER/"settings-fragment.json"),"/tmp/gemini-hooks.sh"]
        normalized=json.loads(subprocess.check_output([str(ADAPTER/"merge-hooks.sh"),"--normalize",str(settings)],text=True))
        merged=json.loads(subprocess.check_output(args,text=True))
        self.assertEqual(merged["endpoint"],"https://example.test/path//segment")
        self.assertEqual(merged["literal"],normalized["literal"])
        self.assertEqual(merged["hooksConfig"],normalized["hooksConfig"])
        self.assertEqual(merged["hooks"]["PreCompress"],[])
        self.assertEqual([h["name"] for h in merged["hooks"]["BeforeModel"][0]["hooks"]],["user-model-hook"])
        settings.write_text(json.dumps(merged))
        self.assertEqual(json.loads(subprocess.check_output(args,text=True)),merged)

    def test_malformed_comments_and_json_are_rejected(self):
        settings=self.root/"settings.json"
        for invalid in ['{/* unclosed', '{"x": 1,}', '{"x": NaN}', '{"x": "unterminated}']:
            settings.write_text(invalid)
            result=subprocess.run([str(ADAPTER/"merge-hooks.sh"),"--normalize",str(settings)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(settings.read_text(),invalid)

    def test_invalid_settings_fail_without_overwrite(self):
        settings=self.root/"settings.json"
        settings.write_text('{"hooks":{"BeforeTool":"invalid"}}')
        before=settings.read_text()
        result=subprocess.run([str(ADAPTER/"merge-hooks.sh"),str(settings),str(ADAPTER/"settings-fragment.json"),"/tmp/hooks.sh"],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(settings.read_text(),before)

if __name__ == "__main__": unittest.main()
