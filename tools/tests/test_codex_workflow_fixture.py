#!/usr/bin/env python3
"""Exercise the offline server in separate processes with disposable state."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "build/codex_workflow_fixture.py"


class CodexWorkflowFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.account = self.root / "account"
        self.workspace = self.root / "workspace"
        self.account.mkdir()
        self.workspace.mkdir()
        self.profile()

    def profile(self, mode="complete"):
        (self.account / "workflow-profile.json").write_text(json.dumps({
            "format": "spica-offline-codex-workflow-v1", "mode": mode, "workspace": str(self.workspace)}))

    def run_server(self, requests, *, cwd=None, account=None):
        return subprocess.run([str(FIXTURE), "app-server", "--stdio"],
            input="".join(json.dumps(value) + "\n" for value in requests),
            text=True, capture_output=True, timeout=5, cwd=cwd or self.workspace,
            env={"PATH": "/usr/bin:/bin", "CODEX_HOME": str(account or self.account)})

    def selection(self, thread=None):
        return dict(model="offline-workflow", modelProvider="openai", cwd=str(self.workspace),
                    config=dict(model_reasoning_effort="low"), **({"threadId": thread} if thread else {}))

    def create(self):
        result = self.run_server([dict(id=1, method="initialize"), dict(id=2, method="account/read"),
            dict(id=3, method="model/list"), dict(id=4, method="thread/start", params=self.selection())])
        self.assertEqual(result.returncode, 0, result.stderr)
        output = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertIn("0.163.0", output[0]["result"]["userAgent"])
        self.assertEqual(output[1]["result"]["account"]["type"], "chatgpt")
        self.assertEqual(output[2]["result"]["data"][0]["model"], "offline-workflow")
        return output[3]["result"]["thread"]["id"]

    def turn(self, thread, prompt):
        return self.run_server([dict(id=1, method="thread/resume", params=self.selection(thread)),
            dict(id=2, method="turn/start", params=dict(threadId=thread, model="offline-workflow", effort="low",
                cwd=str(self.workspace), input=[dict(type="text", text=prompt)]))])

    def test_resumes_persisted_session_and_checks_exact_escaped_utf8_bytes(self):
        thread = self.create()
        prompts = ["界🙂 café", '\n"\\' * 21845 + "x"]
        for index, prompt in enumerate(prompts):
            result = self.turn(thread, prompt)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(output[-1]["params"]["turn"]["status"], "completed")
            self.assertIn(f"prior turns {index}", output[-2]["params"]["delta"])
        events = [json.loads(line) for line in (self.account / "workflow-events.jsonl").read_text().splitlines()]
        turns = [event for event in events if event["method"] == "turn/start"]
        self.assertEqual([turn["prior_turns"] for turn in turns], [0, 1])
        self.assertNotEqual(turns[0]["pid"], turns[1]["pid"])
        self.assertNotEqual(turns[0]["turn_id"], turns[1]["turn_id"])
        self.assertEqual(turns[1]["prompt_bytes"], 65536)
        for event, prompt in zip(turns, prompts):
            self.assertEqual(event["prompt_sha256"], hashlib.sha256(prompt.encode()).hexdigest())
        self.assertNotIn(prompts[0], (self.account / "workflow-state.json").read_text())
        self.assertNotIn(prompts[0], (self.account / "workflow-events.jsonl").read_text())

    def test_synthetic_failure_is_a_terminal_provider_notification(self):
        self.profile("fail")
        result = self.turn(self.create(), "failure")
        self.assertEqual(result.returncode, 0, result.stderr)
        output = [json.loads(line) for line in result.stdout.splitlines()]
        failed = output[-1]["params"]["turn"]
        self.assertEqual(failed["status"], "failed")
        self.assertIn("(synthetic)", failed["error"]["message"])
        self.assertEqual(failed["error"]["codexErrorInfo"], "usageLimitExceeded")
        self.assertFalse(any(value.get("method") == "item/agentMessage/delta" for value in output))

    def test_requires_explicit_profile_and_bound_workspace(self):
        for change in ("workspace", "profile"):
            result = self.run_server([], cwd=self.root) if change == "workspace" else self.run_server([], account=self.workspace)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(result.stdout)
        self.assertFalse((self.workspace / "workflow-state.json").exists())

    def test_unknown_resume_and_oversized_prompt_are_refused(self):
        unknown = self.turn("unowned", "prompt")
        self.assertEqual(unknown.returncode, 1)
        self.assertNotIn("prompt", unknown.stderr)
        thread = self.create()
        oversized = self.turn(thread, "x" * 65537)
        self.assertEqual(oversized.returncode, 1)
        self.assertEqual(json.loads((self.account / "workflow-state.json").read_text())[thread], [])

    def test_cancellation_targets_exact_active_turn_and_separates_rpc_from_terminal(self):
        thread = self.create()
        for mode in ("cancel-start", "cancel-refuse", "cancel-hang"):
            with self.subTest(mode=mode):
                self.profile(mode)
                (self.account / "release-start").touch()
                state = json.loads((self.account / "workflow-state.json").read_text())
                turn = thread + "-turn-" + str(len(state[thread]) + 1)
                result = self.run_server([
                    dict(id=1, method="thread/resume", params=self.selection(thread)),
                    dict(id=2, method="turn/start", params=dict(threadId=thread, model="offline-workflow", effort="low",
                        cwd=str(self.workspace), input=[dict(type="text", text="synthetic cancellation")])),
                    dict(id=3, method="turn/interrupt", params=dict(threadId=thread, turnId=turn))])
                self.assertEqual(result.returncode, 0, result.stderr)
                output = [json.loads(line) for line in result.stdout.splitlines()]
                terminal = [value for value in output if value.get("method") == "turn/completed"]
                replies = [value for value in output if value.get("id") == 3]
                if mode == "cancel-start":
                    self.assertEqual(replies, [dict(id=3, result={})])
                    self.assertEqual(terminal[0]["params"]["turn"]["status"], "interrupted")
                elif mode == "cancel-refuse":
                    self.assertIn("tool state unknown", replies[0]["error"]["message"])
                    self.assertFalse(terminal)
                else:
                    self.assertFalse(replies)
                    self.assertFalse(terminal)
        events = [json.loads(line) for line in (self.account / "workflow-events.jsonl").read_text().splitlines()]
        self.assertEqual(sum(event["method"] == "turn/interrupt" for event in events), 3)

    def test_open_gate_is_explicit_bounded_and_rejects_unexpected_start(self):
        self.profile("cancel-open")
        (self.account / "release-open").touch()
        thread = self.create()
        result = self.turn(thread, "must not start")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("must not start", result.stderr)
        self.assertEqual(json.loads((self.account / "workflow-state.json").read_text())[thread], [])
        (self.account / "release-open").unlink()
        profile = json.loads((self.account / "workflow-profile.json").read_text())
        profile["gate_timeout_ms"] = 30
        (self.account / "workflow-profile.json").write_text(json.dumps(profile))
        timeout = self.run_server([dict(id=1, method="thread/resume", params=self.selection(thread))])
        self.assertEqual(timeout.returncode, 1)
        self.assertFalse(timeout.stdout)

    def test_cancel_fixture_refuses_a_different_turn(self):
        thread = self.create()
        self.profile("cancel-refuse")
        result = self.run_server([
            dict(id=1, method="thread/resume", params=self.selection(thread)),
            dict(id=2, method="turn/start", params=dict(threadId=thread, model="offline-workflow", effort="low",
                cwd=str(self.workspace), input=[dict(type="text", text="synthetic cancellation")])),
            dict(id=3, method="turn/interrupt", params=dict(threadId=thread, turnId="wrong-turn"))])
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any(json.loads(line).get("id") == 3 for line in result.stdout.splitlines()))


    def test_attachment_native_inputs_maximum_escaping_and_binary_roundtrip(self):
        session = self.create()
        prompt = "\x01" * (64 * 1024)
        for index, image in enumerate((True, False)):
            content = b"\xff" * (256 * 1024) if image else b"\x01" * (256 * 1024)
            part = ({"type": "image", "url": "data:image/png;base64," + base64.b64encode(content).decode()}
                    if image else {"type": "text", "text": "[Attached text file fixture]\n" + content.decode()})
            turn = dict(id=3, method="turn/start", params=dict(threadId=session, input=[{"type": "text", "text": prompt}, part],
                        model="offline-workflow", effort="low", cwd=str(self.workspace)))
            result = self.run_server([dict(id=1, method="thread/resume", params=self.selection(session)), turn])
            self.assertEqual(result.returncode, 0, result.stderr)
            events = [json.loads(line) for line in (self.account / "workflow-events.jsonl").read_text().splitlines()]
            accepted = [event for event in events if event["method"] == "turn/start"][-1]
            self.assertEqual(accepted["attachments"][0]["sha256"], hashlib.sha256(content).hexdigest())
            self.assertEqual(accepted["attachments"][0]["byte_length"], len(content))
            self.assertEqual(accepted["prompt_bytes"], len(prompt))

    def test_rejects_non_native_image_and_attachment_count_overflow(self):
        session = self.create()
        for parts in ([{"type": "image", "url": "data:image/png;base64,%%%"}],
                      [{"type": "text", "text": "p"}] * 10,
                      [{"type": "file", "url": "file:///private"}]):
            turn = dict(id=3, method="turn/start", params=dict(threadId=session, input=parts,
                        model="offline-workflow", effort="low", cwd=str(self.workspace)))
            result = self.run_server([dict(id=1, method="thread/resume", params=self.selection(session)), turn])
            self.assertNotEqual(result.returncode, 0)

    def test_steer_accepts_native_attachments_and_completes_active_turn(self):
        self.profile("cancel-hang")
        thread = self.create()
        image = b"\x00\xfffixture-image"
        steer = [{"type": "text", "text": "continue with image"},
                 {"type": "image", "url": "data:image/png;base64," + base64.b64encode(image).decode()}]
        result = self.run_server([
            dict(id=1, method="thread/resume", params=self.selection(thread)),
            dict(id=2, method="turn/start", params=dict(threadId=thread, model="offline-workflow", effort="low",
                cwd=str(self.workspace), input=[dict(type="text", text="hold active turn")])),
            dict(id=3, method="turn/steer", params=dict(threadId=thread,
                expectedTurnId=thread + "-turn-1", input=steer)),
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        output = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([value for value in output if value.get("id") == 3],
                         [dict(id=3, result={"turnId": thread + "-turn-1"})])
        self.assertEqual(output[-1]["params"]["turn"]["status"], "completed")
        events = [json.loads(line) for line in (self.account / "workflow-events.jsonl").read_text().splitlines()]
        steered = [event for event in events if event["method"] == "turn/steer"]
        self.assertEqual(len(steered), 1)
        self.assertTrue(steered[0]["steering"])
        self.assertEqual(steered[0]["attachments"][0]["sha256"], hashlib.sha256(image).hexdigest())


if __name__ == "__main__":
    unittest.main()
