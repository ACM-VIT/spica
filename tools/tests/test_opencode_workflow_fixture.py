#!/usr/bin/env python3
"""Exercise the offline OpenCode ACP fixture without network or installed auth."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "build/opencode_workflow_fixture.py"
FORMAT = "spica-offline-opencode-workflow-v1"
WORKSPACE = "workspace"


class OpenCodeWorkflowFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.account = root / "account"
        self.workspace = root / WORKSPACE
        self.account.mkdir()
        self.workspace.mkdir()
        self.profile()

    def profile(self, mode="complete"):
        (self.account / "workflow-profile.json").write_text(json.dumps({
            "format": FORMAT, "mode": mode, "runtime_version": "2.1.4",
            "protocol_version": 1, "model_provider": "opencode", "model": "big-pickle",
            "effort": "default", "workspace": str(self.workspace)}), encoding="utf-8")

    def run_server(self, requests, *, cwd=None, account=None):
        payload = "".join(json.dumps(value, ensure_ascii=False) + "\n" for value in requests)
        env = {"PATH": "/usr/bin:/bin", "OPENCODE_TEST_HOME": str(account or self.account)}
        return subprocess.run([str(FIXTURE), "acp"], input=payload, text=True,
                              capture_output=True, timeout=5, cwd=cwd or self.workspace, env=env)

    @staticmethod
    def initialize():
        return {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "test", "version": "1"}}}

    def new(self, identifier=2):
        return {"jsonrpc": "2.0", "id": identifier, "method": "session/new",
                "params": {"cwd": str(self.workspace), "mcpServers": []}}

    def resume(self, session, identifier=1):
        return {"jsonrpc": "2.0", "id": identifier, "method": "session/resume",
                "params": {"sessionId": session, "cwd": str(self.workspace), "mcpServers": []}}

    def configure(self, identifier=3, session=None):
        return {"jsonrpc": "2.0", "id": identifier, "method": "session/set_config_option",
                "params": {"sessionId": session, "configId": "model", "value": "opencode/big-pickle"}}

    def prompt(self, identifier, session, text):
        return {"jsonrpc": "2.0", "id": identifier, "method": "session/prompt",
                "params": {"sessionId": session, "prompt": [{"type": "text", "text": text}]}}

    def create(self):
        result = self.run_server([self.initialize(), self.new()])
        self.assertEqual(result.returncode, 0, result.stderr)
        output = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(output[0]["result"]["protocolVersion"], 1)
        self.assertEqual(output[0]["result"]["agentInfo"]["version"], "2.1.4")
        self.assertIn("resume", output[0]["result"]["agentCapabilities"]["sessionCapabilities"])
        self.assertTrue(output[1]["result"]["sessionId"])
        return output[1]["result"]["sessionId"]

    def test_handshake_model_prompt_and_exact_utf8_digests(self):
        prompts = ["ASCII " + "x" * 32, "🙂 café 世界", '\n"\\\t' * 32,
                   "x" * 2047 + "€" + "\x01" * 128]
        session = self.create()
        for index, value in enumerate(prompts):
            requests = [self.resume(session, 10 + index * 3), self.configure(11 + index * 3, session),
                        self.prompt(12 + index * 3, session, value)]
            result = self.run_server(requests)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(output[-1]["result"]["stopReason"], "end_turn")
            self.assertIn(f"prior turns {index}", output[-2]["params"]["update"]["content"]["text"])
        events = [json.loads(line) for line in (self.account / "workflow-events.jsonl").read_text().splitlines()]
        sessions = [event for event in events if event["method"] == "session/new"]
        turns = [event for event in events if event["method"] == "session/prompt"]
        self.assertEqual(len(sessions), 1)
        self.assertEqual(len(turns), len(prompts))
        self.assertEqual([turn["prior_turns"] for turn in turns], list(range(len(prompts))))
        self.assertEqual({turn["session_id"] for turn in turns}, {sessions[0]["session_id"]})
        for turn, prompt in zip(turns, prompts):
            data = prompt.encode()
            self.assertEqual(turn["prompt_bytes"], len(data))
            self.assertEqual(turn["prompt_sha256"], hashlib.sha256(data).hexdigest())
        state = (self.account / "workflow-state.json").read_text()
        self.assertNotIn(prompts[1], state)

    def test_restart_resume_preserves_one_upstream_session_and_context_count(self):
        session = self.create()
        first = self.run_server([self.resume(session), self.configure(2, session), self.prompt(3, session, "one")])
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.run_server([self.resume(session), self.configure(2, session), self.prompt(3, session, "two")])
        self.assertEqual(second.returncode, 0, second.stderr)
        events = [json.loads(line) for line in (self.account / "workflow-events.jsonl").read_text().splitlines()]
        self.assertEqual(len([event for event in events if event["method"] == "session/new"]), 1)
        self.assertEqual(len([event for event in events if event["method"] == "session/resume"]), 2)
        turns = [event for event in events if event["method"] == "session/prompt"]
        self.assertEqual([turn["prior_turns"] for turn in turns], [0, 1])
        self.assertEqual(len({turn["turn_id"] for turn in turns}), 2)

    def test_accepts_all_four_exact_64k_prompt_shapes(self):
        prompts = ["x" * 65536, "🙂" * 16384, '\n"\\\t' * 16384,
                   "x" * 2047 + "€" + "\x01" * 63486]
        self.assertEqual([len(prompt.encode()) for prompt in prompts], [65536] * 4)
        session = self.create()
        for index, prompt in enumerate(prompts):
            result = self.run_server([self.resume(session), self.configure(2, session),
                                      self.prompt(3, session, prompt)])
            self.assertEqual(result.returncode, 0, result.stderr)
            output = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(output[-1]["result"]["stopReason"], "end_turn")
            self.assertIn(f"prompt bytes 65536", output[-2]["params"]["update"]["content"]["text"])
        turns = [json.loads(line) for line in (self.account / "workflow-events.jsonl").read_text().splitlines()
                 if json.loads(line).get("method") == "session/prompt"]
        self.assertEqual([turn["prior_turns"] for turn in turns], list(range(4)))
        for turn, prompt in zip(turns, prompts):
            self.assertEqual(turn["prompt_sha256"], hashlib.sha256(prompt.encode()).hexdigest())

    def test_failure_is_terminal_synthetic_provider_stop(self):
        self.profile("fail")
        session = self.create()
        result = self.run_server([self.resume(session), self.configure(2, session), self.prompt(3, session, "failure")])
        self.assertEqual(result.returncode, 0, result.stderr)
        output = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(output[-1]["result"]["stopReason"], "Offline synthetic OpenCode provider failure (synthetic).")
        self.assertFalse(any(value.get("method") == "session/update" for value in output))

    def test_refuses_profile_protocol_bounds_duplicate_and_wrong_session(self):
        malformed = self.run_server([self.initialize()], cwd=self.account)
        self.assertEqual(malformed.returncode, 1)
        bad_protocol = self.run_server([{"jsonrpc": "1.0", "id": 1, "method": "initialize", "params": {}}])
        self.assertEqual(bad_protocol.returncode, 1)
        wrong = self.run_server([self.initialize(), self.resume("missing", 2)])
        self.assertEqual(wrong.returncode, 0)
        self.assertIn("session not found", wrong.stdout)
        duplicate = self.run_server([self.initialize(), self.initialize()])
        self.assertEqual(duplicate.returncode, 1)
        oversized_frame = subprocess.run([str(FIXTURE), "acp"], input=("x" * (512 * 1024 + 1)) + "\n",
                                         text=True, capture_output=True, timeout=5, cwd=self.workspace,
                                         env={"PATH": "/usr/bin:/bin", "OPENCODE_TEST_HOME": str(self.account)})
        self.assertEqual(oversized_frame.returncode, 1)
        session = self.create()
        wrong_prompt = self.run_server([self.resume(session), self.configure(2, session), self.prompt(3, "wrong", "secret")])
        self.assertEqual(wrong_prompt.returncode, 1)
        self.assertNotIn("secret", wrong_prompt.stderr)
        oversized = self.run_server([self.resume(session), self.configure(2, session), self.prompt(3, session, "x" * 65537)])
        self.assertEqual(oversized.returncode, 1)
        state = json.loads((self.account / "workflow-state.json").read_text())
        self.assertEqual(len(state[session]), 0)

    def test_cli_regression_is_offline_and_dry_run_pins_fixture(self):
        result = subprocess.run(["python3", str(ROOT / "tools/spica-ui"), "launch", "--private",
                                 "--provider", "opencode-fixture", "--output", self.temporary.name, "--dry-run"],
                                text=True, capture_output=True, cwd=ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["provider"], "opencode-fixture")
        self.assertEqual(plan["argv"][plan["argv"].index("--runtime-executable") + 1],
                         str(ROOT / "build/opencode_workflow_fixture.py"))
        no_network = subprocess.run(["python3", str(ROOT / "tools/spica-ui"), "scenario", "opencode-session",
                                     "--provider", "fake", "--output", self.temporary.name, "--dry-run"],
                                    text=True, capture_output=True, cwd=ROOT)
        self.assertEqual(no_network.returncode, 15)


if __name__ == "__main__":
    unittest.main()
