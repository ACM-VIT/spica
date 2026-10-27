#!/usr/bin/env python3
"""Offline contract checks for tools/spica-ui.

These tests intentionally do not start a desktop, build the native binary, or
inspect an application database.  The real desktop cohort belongs to an
explicitly invoked scenario command.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "tools" / "spica-ui"


def load_cli():
    loader = importlib.machinery.SourceFileLoader("spica_ui", str(CLI))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SpicaUiOfflineTests(unittest.TestCase):
    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(CLI), *args], cwd=ROOT, text=True,
                              capture_output=True, check=False)

    def test_python_syntax(self):
        result = subprocess.run(["python3", "-m", "py_compile", str(CLI)], cwd=ROOT,
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_help_is_offline(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("scenario", result.stdout)
        self.assertIn("ordinary private-desktop", result.stdout)

    def test_vd_symlink_resolves_to_packaged_resource_directory(self):
        module = load_cli()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "scripts" / "vd.py"
            script.parent.mkdir()
            script.touch()
            launcher = root / "vd"
            launcher.symlink_to(script)
            with patch.object(module.shutil, "which", return_value=str(launcher)), \
                    patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
                module.run_command(["vd", "preflight"])
            self.assertEqual(run.call_args.args[0], [str(script), "preflight"])

    def test_text_delivery_failures_do_not_echo_private_arguments(self):
        module = load_cli()
        content = "private fixture prompt"
        with patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, content, content)):
            with self.assertRaises(module.DriverError) as failure:
                module.run_command(["wl-copy", content], private=True)
            self.assertNotIn(content, str(failure.exception))
        with patch.object(module.subprocess, "run", side_effect=subprocess.TimeoutExpired(["wl-copy", content], 1)):
            with self.assertRaises(module.DriverError) as failure:
                module.run_command(["wl-copy", content], private=True)
            self.assertNotIn(content, str(failure.exception))

    def test_launch_dry_run_does_not_require_binary_or_vd(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_cli("launch", "--private", "--provider", "fake",
                                  "--output", directory, "--dry-run")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"provider": "fake"', result.stdout)
            self.assertFalse((Path(directory) / "session.json").exists())

    def test_root_dry_run_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_cli("--dry-run", "scenario", "disabled-send", "--output", directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"command": "scenario"', result.stdout)
            self.assertFalse((Path(directory) / "session.json").exists())

    def test_input_and_wait_dry_runs_are_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            for command in (("click", "command.send"), ("key", "Return"),
                            ("wait", "--command", "exact-command", "--receipt", "accepted"), ("receipt",)):
                result = self.run_cli(*command, "--output", directory, "--dry-run")
                self.assertEqual(result.returncode, 0, (command, result.stderr))
            self.assertFalse((Path(directory) / "session.json").exists())

    def test_rejected_scenario_bounds_fixture_size(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_cli("scenario", "rejected-send", "--output", directory,
                                  "--rejected-bytes", "4096", "--dry-run")
            self.assertEqual(result.returncode, 2)
            self.assertIn("between 4097 and 65536", result.stderr)

    def test_redaction_does_not_leak_account_material(self):
        module = load_cli()
        value = module.redact({"account_directory": "/tmp/private", "nested": {"token": "secret"},
                               "model": "fixture"})
        self.assertEqual(value["account_directory"], "<redacted>")
        self.assertEqual(value["nested"]["token"], "<redacted>")
        self.assertEqual(value["model"], "fixture")
        omitted = module.redact({"draft": "private prompt", "transcript": ["private reply"]})
        self.assertEqual(omitted, {"draft": "<omitted>", "transcript": "<omitted>"})

    def test_new_scenarios_have_offline_plans(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ("second-turn", "oversized-send", "workspace-diff", "capability-refusal",
                         "followup-refusal", "question-refusal"):
                result = self.run_cli("scenario", name, "--output", directory, "--dry-run")
                self.assertEqual(result.returncode, 0, (name, result.stderr))
                self.assertTrue(json.loads(result.stdout)["steps"])
            self.assertFalse((Path(directory) / "session.json").exists())

    def test_wait_requires_exact_identity_even_in_dry_run(self):
        for args in (("--receipt", "accepted"), ("--run", "run", "--receipt", "rejected")):
            result = self.run_cli("wait", *args, "--dry-run")
            self.assertEqual(result.returncode, 2)
            self.assertIn("exact --command", result.stderr)

    def test_wait_never_accepts_old_run_or_unrelated_rejection(self):
        module = load_cli()
        value = {"run_id": "old-run", "run_status": "completed", "send_command_id": "old-command",
                 "send_run_id": "old-run", "send_receipt": "accepted", "admission_errors": 1}
        self.assertFalse(module.matches_wait(value, command_id="new-command", receipt="accepted"))
        self.assertFalse(module.matches_wait(value, command_id="old-command", run="new-run", state="completed"))
        self.assertFalse(module.matches_wait(value, command_id="old-command", receipt="rejected"))
        self.assertTrue(module.matches_wait(value, command_id="old-command", run="old-run", receipt="accepted", state="completed"))
        value["send_run_id"] = "different-run"
        self.assertFalse(module.matches_wait(value, command_id="old-command", run="old-run", state="completed"))

    def test_workspace_targets_come_from_navigation_observation(self):
        module = load_cli()
        target = {"id": "workspace.file.0", "enabled": True, "pointer_bounds": [10, 20, 30, 40]}
        self.assertEqual(module.find_target({"navigation_targets": [target]}, "workspace.file.0"), target)

    def test_workspace_diff_requires_fresh_result_in_the_same_checkout_and_thread(self):
        module = load_cli()
        before = {"workspace_root": "/fixture", "workspace_revision": 2, "project_id": "p", "thread_id": "t"}
        current = {**before, "workspace_revision": 3, "workspace_file_count": 1, "workspace_diff_bytes": 100}
        module.assert_workspace_diff(before, current, "/fixture")
        for changed in ({"workspace_root": "/other"}, {"project_id": "other"}, {"thread_id": "other"},
                        {"workspace_stale": True}, {"workspace_revision": 2}, {"workspace_busy": True},
                        {"workspace_diff_bytes": 0}, {"workspace_file_count": 0}, {"run_id": "unexpected"},
                        {"send_command_id": "unexpected"}):
            with self.assertRaises(module.DriverError):
                module.assert_workspace_diff(before, {**current, **changed}, "/fixture")

    def test_oversized_refusal_requires_preserved_draft_and_no_command(self):
        module = load_cli()
        before = {"run_id": "", "send_command_id": ""}
        current = {**before, "draft": "x" * 6000, "send_frame_bytes": 6200,
                   "send_disabled_reason": "Shorten the message", "pending_command": False,
                   "targets": [{"id": "command.send", "enabled": False}]}
        module.assert_oversized_refusal(before, current, 6000)
        for changed in ({"draft": ""}, {"send_command_id": "unexpected"}, {"run_id": "unexpected"},
                        {"send_frame_bytes": 4000}, {"pending_command": True}):
            with self.assertRaises(module.DriverError):
                module.assert_oversized_refusal(before, {**current, **changed}, 6000)

    def test_empty_send_is_disabled_without_creating_command_or_run(self):
        module = load_cli()
        current = {"draft": "", "send_ready": True, "send_disabled_reason": None,
                   "targets": [{"id": "command.send", "enabled": False}]}
        module.assert_empty_send_disabled(current)
        for changed in ({"draft": "unexpected"}, {"pending_command": True},
                        {"send_command_id": "unexpected"}, {"run_id": "unexpected"},
                        {"targets": [{"id": "command.send", "enabled": True}]}):
            with self.assertRaises(module.DriverError):
                module.assert_empty_send_disabled({**current, **changed})

    def test_capability_refusal_delivers_no_input_or_host_command(self):
        module = load_cli()
        snapshot = {"thread_id": "thread", "run_id": "", "send_command_id": "", "draft_revision": 0}
        session = Mock()
        session.snapshot.return_value = snapshot
        session.data = {"limitations": []}
        with patch.object(module, "composer_ready", return_value=snapshot), patch.object(module, "run_command") as command:
            module.capability_refusal(session, 1, ("followup.enqueue", "question.answer"))
        command.assert_not_called()
        self.assertEqual(session.journal.call_count, 2)
        for call in session.journal.call_args_list:
            self.assertFalse(call.kwargs["input_delivered"])
        supported = {**snapshot, "targets": [{"id": "question.answer", "enabled": True, "pointer_bounds": [0, 0, 20, 20]}]}
        with patch.object(module, "composer_ready", return_value=supported), self.assertRaises(module.DriverError):
            module.capability_refusal(session, 1, ("question.answer",))

    def test_restart_keeps_private_desktop_and_uses_fresh_observations(self):
        module = load_cli()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            session = module.Session(output, {"launch": {"pid": 100}, "binary": "/fixture/spica",
                "private_desktop": {"session": "/private/vd"}, "workspace": "/fixture/workspace"})
            before = {"thread_id": "thread", "run_id": "run", "run_status": "completed"}
            session.snapshot = Mock(return_value=before)

            def command(argv, **kwargs):
                return subprocess.CompletedProcess(argv, 0, '7 app' if argv[1] == "windows" else '{"pid":101}', '')

            with patch.object(module, "close_app") as close, patch.object(module, "run_command", side_effect=command), \
                    patch.object(module, "wait_snapshot", return_value=before):
                module.restart_app(session, argparse.Namespace(timeout=1, quit_after_ms=1000))
            close.assert_called_once_with(session, 1, clean_desktop=False)
            self.assertEqual(session.data["launch"]["pid"], 101)
            self.assertEqual(session.observations, output / "restart-process" / "live.json")
            self.assertEqual(session.data["actions"][0]["action"], "scenario.restart")


if __name__ == "__main__":
    unittest.main()
