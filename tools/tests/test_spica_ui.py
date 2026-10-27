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
import hashlib
import json
import os
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

    def test_title_assertion_requires_header_sidebar_commit_and_retained_draft(self):
        module = load_cli()
        saved = {"title_editing": False, "pending_command": False, "title_text": "Native café 🎮",
                 "thread_labels": ["Native café 🎮"], "draft": "retained"}
        module.assert_chat_title(saved, "Native café 🎮", "retained")
        for changed in ({"title_editing": True}, {"pending_command": True}, {"title_text": "old"},
                        {"thread_labels": ["old"]}, {"draft": "lost"}):
            with self.assertRaises(module.DriverError):
                module.assert_chat_title({**saved, **changed}, "Native café 🎮", "retained")

    def test_title_scenario_dry_run_is_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_cli("scenario", "thread-title", "--output", directory, "--dry-run")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Unicode title", result.stdout)
            self.assertIn("restart", result.stdout)
            self.assertFalse((Path(directory) / "session.json").exists())

    def test_history_scenarios_dry_run_never_create_state(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ("history-deep", "history-wide"):
                result = self.run_cli("scenario", name, "--output", directory, "--dry-run")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("public Host", result.stdout)
                self.assertEqual(json.loads(result.stdout)["provider"], "fake")
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_history_fixture_requires_exact_paths_counts_and_successful_exit(self):
        module = load_cli()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            binary = output / "spica"
            executable = output / "build-history-fixture"
            executable.write_text("synthetic test executable")
            executable.chmod(0o700)
            manifest = {"fixture": "synthetic-large-history", "generated_threads": 2,
                        "generated_turns": 260, "generated_messages": 520, "completed_runs": 260,
                        "cancelled_runs": 0, "state_path": str(output / "state"),
                        "workspace_path": str(output / "workspace"), "latest_thread_id": "last",
                        "provenance": {"git_initialized": True}}
            for changed in ({"state_path": "/other"}, {"workspace_path": "/other"},
                            {"completed_runs": 259}, {"generated_messages": 518}, {"latest_thread_id": ""},
                            {"provenance": {"git_initialized": False}}):
                with patch.object(module, "run_command", return_value=subprocess.CompletedProcess([], 0, json.dumps({**manifest, **changed}), "")):
                    with self.assertRaises(module.DriverError):
                        module.prepare_history_fixture(binary, output, "history-deep")
                self.assertFalse((output / "history-fixture.json").exists())
            with patch.object(module, "run_command", side_effect=module.DriverError("fixture failed")):
                with self.assertRaises(module.DriverError):
                    module.prepare_history_fixture(binary, output, "history-deep")
            with patch.object(module, "run_command", return_value=subprocess.CompletedProcess([], 0, json.dumps(manifest), "")) as run:
                result = module.prepare_history_fixture(binary, output, "history-deep")
            self.assertEqual(result["manifest"], manifest)
            self.assertEqual(run.call_args.kwargs["timeout"], 180)
            self.assertEqual(json.loads((output / "history-fixture.json").read_text()), manifest)

    def test_history_page_assertion_requires_identity_draft_bounded_tiles_and_no_commands(self):
        module = load_cli()
        before = {"thread_id": "thread", "run_id": "run", "send_command_id": "",
                  "send_run_id": "", "pending_command": False}
        page = {**before, "draft": "retained", "follow_latest": False, "visible_rich_blocks": 8,
                "transcript_message_ids": ["message", ""], "transcript_ordinals": [0, 999]}
        self.assertEqual(module.history_ordinals(page), [0])
        module.assert_history_page(before, page, draft="retained", latest=False)
        for changed in ({"thread_id": "other"}, {"run_id": "other"}, {"send_command_id": "new"},
                        {"draft": "lost"}, {"visible_rich_blocks": 9}, {"follow_latest": True},
                        {"transcript_message_ids": []}, {"notice": "QueryFailed"}):
            with self.assertRaises(module.DriverError):
                module.assert_history_page(before, {**page, **changed}, draft="retained", latest=False)

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

    def test_process_identity_tracks_the_current_executable_lifetime(self):
        module = load_cli()
        identity = module.process_identity(os.getpid())
        self.assertEqual(identity["pid"], os.getpid())
        self.assertGreater(identity["starttime_ticks"], 0)
        self.assertGreater(identity["executable_inode"], 0)
        self.assertEqual(identity, module.process_identity(os.getpid()))

    def test_liveness_rejects_pid_reuse_and_window_reassignment(self):
        module = load_cli()
        identity = {"pid": 42, "starttime_ticks": 10, "executable_device": 1, "executable_inode": 2}
        session = module.Session(Path("/unused"), {"launch": {"pid": 42}, "process_identity": identity})
        with patch.object(module, "process_identity", return_value=identity), \
                patch.object(module, "window_node", return_value={"pid": 42}):
            session.require_live()
        for actual, window_pid in (({**identity, "starttime_ticks": 11}, 42), (identity, 43)):
            with patch.object(module, "process_identity", return_value=actual), \
                    patch.object(module, "window_node", return_value={"pid": window_pid}), \
                    self.assertRaises(module.DriverError) as failure:
                session.require_live()
            self.assertEqual(failure.exception.code, module.EX_STALE)

    def test_snapshot_rejects_other_sessions_and_backwards_counters_but_allows_idle(self):
        module = load_cli()
        observed = {"version": 2, "process_nonce": "a" * 32, "generation": 10, "frame_id": 10, "event_sequence": 8}
        session = module.Session(Path("/unused"), {"process_nonce": "a" * 32, "observations": "/unused/live.json"})
        session.require_live = Mock()
        session.save = Mock()
        with patch.object(module, "read_json", return_value=observed):
            session.snapshot()
            session.snapshot()  # An event-driven idle application need not repaint.
        for changed in ({"process_nonce": "b" * 32}, {"generation": 9}, {"frame_id": 9},
                        {"event_sequence": 7}, {"generation": None}, {"version": "2"},
                        {"version": 999}, {"frame_id": True}):
            with patch.object(module, "read_json", return_value={**observed, **changed}), \
                    self.assertRaises(module.DriverError) as failure:
                session.snapshot()
            self.assertEqual(failure.exception.code, module.EX_STALE)

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

    def test_full_size_scenario_covers_exact_utf8_bytes_and_sixfold_json_escaping(self):
        prompts = load_cli().full_size_prompts()
        self.assertEqual([len(value.encode()) for value in prompts], [65536] * 4)
        self.assertGreater(len(json.dumps(prompts[-1])), 6 * 63486)

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
            for name in ("second-turn", "large-send", "codex-large-send", "opencode-large-send", "composer-capacity", "workspace-diff", "capability-refusal",
                         "followup-refusal", "question-refusal", "attachment-refusal", "codex-session", "codex-error", "opencode-session", "opencode-error"):
                result = self.run_cli("scenario", name, "--output", directory, "--dry-run")
                self.assertEqual(result.returncode, 0, (name, result.stderr))
                self.assertTrue(json.loads(result.stdout)["steps"])
            self.assertFalse((Path(directory) / "session.json").exists())

    def test_codex_fixture_dry_run_pins_only_the_repo_fixture_and_disposable_account(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_cli("launch", "--provider", "codex-fixture", "--private", "--output", directory, "--dry-run")
            self.assertEqual(result.returncode, 0, result.stderr)
            argv = json.loads(result.stdout)["argv"]
            self.assertEqual(argv[argv.index("--runtime-executable") + 1], str(ROOT / "build/codex_workflow_fixture.py"))
            self.assertEqual(argv[argv.index("--runtime-account-directory") + 1], str(Path(directory) / "codex-fixture-account"))
            self.assertFalse((Path(directory) / "codex-fixture-account").exists())
            mismatch = self.run_cli("scenario", "codex-session", "--provider", "fake", "--dry-run")
            self.assertEqual(mismatch.returncode, 15)

    def test_opencode_fixture_dry_run_pins_exact_acp_fixture_and_disposable_account(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_cli("launch", "--provider", "opencode-fixture", "--private",
                                  "--output", directory, "--dry-run")
            self.assertEqual(result.returncode, 0, result.stderr)
            argv = json.loads(result.stdout)["argv"]
            self.assertEqual(argv[argv.index("--runtime-executable") + 1],
                             str(ROOT / "build/opencode_workflow_fixture.py"))
            self.assertEqual(argv[argv.index("--runtime-account-directory") + 1],
                             str(Path(directory) / "opencode-fixture-account"))
            self.assertFalse((Path(directory) / "opencode-fixture-account").exists())
            mismatch = self.run_cli("scenario", "opencode-session", "--provider", "fake", "--dry-run")
            self.assertEqual(mismatch.returncode, 15)

    def test_opencode_fixture_trace_rejects_fresh_sessions_missing_turns_and_changed_prompt_bytes(self):
        module = load_cli()
        prompt = "café 世界"
        start = {"method": "session/new", "session_id": "session"}
        turn = {"method": "session/prompt", "session_id": "session", "turn_id": "turn", "prior_turns": 0,
                "prompt_bytes": len(prompt.encode()), "prompt_sha256": hashlib.sha256(prompt.encode()).hexdigest()}
        module.assert_opencode_fixture_trace([start, turn], [prompt])
        module.assert_opencode_fixture_trace([{"method": "session/new", "session_id": "unprompted-catalog"}, start, turn], [prompt])
        with self.assertRaises(module.DriverError):
            module.assert_opencode_fixture_trace([start, turn, {"method": "session/resume", "session_id": "wrong"}], [prompt], require_resume=True)
        for events in ([start, start, turn], [start], [start, {**turn, "prior_turns": 1}],
                       [start, {**turn, "session_id": "other"}], [start, {**turn, "turn_id": ""}],
                       [start, {**turn, "prompt_bytes": 2}], [start, {**turn, "prompt_sha256": "wrong"}]):
            with self.assertRaises(module.DriverError):
                module.assert_opencode_fixture_trace(events, [prompt])

    def test_codex_fixture_trace_rejects_fresh_sessions_missing_turns_and_changed_prompt_bytes(self):
        module = load_cli()
        prompt = "café 世界"
        start = {"method": "thread/start", "thread_id": "session"}
        turn = {"method": "turn/start", "thread_id": "session", "turn_id": "turn", "prior_turns": 0,
                "prompt_bytes": len(prompt.encode()), "prompt_sha256": hashlib.sha256(prompt.encode()).hexdigest()}
        module.assert_codex_fixture_trace([start, turn], [prompt])
        for events in ([start, start, turn], [start], [start, turn, turn],
                       [start, {**turn, "prior_turns": 1}], [start, {**turn, "thread_id": "other"}],
                       [start, {**turn, "turn_id": ""}], [start, {**turn, "prompt_bytes": 2}],
                       [start, {**turn, "prompt_sha256": "wrong"}]):
            with self.assertRaises(module.DriverError):
                module.assert_codex_fixture_trace(events, [prompt])

    def test_private_clipboard_reads_command_log_instead_of_vd_launch_receipt(self):
        module = load_cli()
        with tempfile.TemporaryDirectory() as directory:
            session = module.Session(Path(directory), {"private_desktop": {"session": "/private-desktop"}})
            payload = '{"provider_diagnostic":"synthetic café 世界"}'
            def run(argv, **kwargs):
                Path(argv[argv.index("--log") + 1]).write_text(payload)
                return subprocess.CompletedProcess(argv, 0, '{"pid":42,"log":"fixture"}', "")
            with patch.object(module, "run_command", side_effect=run):
                self.assertEqual(module.read_private_clipboard(session), payload)
                with self.assertRaises(module.DriverError):
                    module.read_private_clipboard(session)

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

    def test_workflow_targets_preserve_painted_bounds_and_disabled_state(self):
        module = load_cli()
        opener = {"id": "workflow.open", "enabled": True, "pointer_bounds": [10, 20, 30, 40]}
        remove = {"id": "attachment.remove.0", "enabled": False, "pointer_bounds": None}
        snapshot = {"workflow_target": opener, "workflow_targets": [remove]}
        self.assertEqual(module.find_target(snapshot, "workflow.open"), opener)
        with self.assertRaises(module.DriverError) as failure:
            module.find_target(snapshot, "attachment.remove.0")
        self.assertEqual(failure.exception.code, module.EX_TARGET)
        self.assertIn("disabled", str(failure.exception))

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

    def test_over_capacity_paste_requires_original_draft_revision_and_no_command(self):
        module = load_cli()
        before = {"run_id": "", "send_command_id": "", "draft_revision": 2}
        current = {**before, "draft": "retained", "notice": "TextTooLarge"}
        module.assert_composer_capacity(before, current, "retained")
        for changed in ({"draft": ""}, {"send_command_id": "unexpected"}, {"run_id": "unexpected"},
                        {"draft_revision": 3}, {"notice": ""}, {"pending_command": True}):
            with self.assertRaises(module.DriverError):
                module.assert_composer_capacity(before, {**current, **changed}, "retained")

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

    def test_followup_refusal_checks_all_slots_and_preserves_draft(self):
        module = load_cli()
        before = {"run_id": "run", "send_command_id": "send", "send_run_id": "run", "pending_command": False}
        refused = {**before, "draft": "draft café 世界", "workflow_error": "FollowupCapabilityUnavailable",
                   "followup_ids": ["", ""], "followup_states": ["", ""]}
        module.assert_followup_refusal(before, refused, refused["draft"])
        for changed in ({"followup_ids": ["", "unexpected"]}, {"followup_states": ["", "queued"]},
                        {"draft": ""}, {"run_id": "other"}, {"pending_command": True}):
            with self.assertRaises(module.DriverError):
                module.assert_followup_refusal(before, {**refused, **changed}, refused["draft"])

    def test_cancellation_requires_cancelled_same_run_and_retained_draft(self):
        module = load_cli()
        before = {"run_id": "run"}
        cancelled = {"run_id": "run", "run_status": "cancelled", "draft": "retained", "pending_command": False}
        module.assert_cancelled_draft(before, cancelled, "retained")
        for changed in ({"run_status": "completed"}, {"run_status": "interrupted"},
                        {"run_id": "other"}, {"draft": ""}, {"pending_command": True}):
            with self.assertRaises(module.DriverError):
                module.assert_cancelled_draft(before, {**cancelled, **changed}, "retained")

    def test_attachment_refusal_preserves_local_bytes_draft_and_provider_identity(self):
        module = load_cli()
        before = {"thread_id": "thread", "run_id": "", "send_command_id": "", "send_run_id": "",
                  "pending_command": False}
        current = {**before, "draft": "attachment draft café 世界", "workflow_path": "/tmp/notes-café.txt",
                   "attachment_count": 1, "attachment_bytes": 64, "workflow_error": "capability_unavailable",
                   "workflow_feedback": "Attachments are unavailable. File kept locally; nothing sent."}
        module.assert_attachment_refusal(before, current, current["workflow_path"], current["draft"], 64)
        for changed in ({"attachment_count": 0}, {"attachment_bytes": 0}, {"draft": ""},
                        {"send_command_id": "new"}, {"workflow_error": "unexpected"}):
            with self.assertRaises(module.DriverError):
                module.assert_attachment_refusal(before, {**current, **changed}, current["workflow_path"], current["draft"], 64)

    def test_oversized_attachment_refusal_is_local_read_refusal_without_command_or_run(self):
        module = load_cli()
        before = {"thread_id": "thread", "run_id": "", "send_command_id": "", "send_run_id": "",
                  "pending_command": False}
        current = {**before, "draft": "draft", "workflow_path": "/tmp/oversized-café.txt", "attachment_count": 0,
                   "attachment_bytes": 0, "workflow_error": "StreamTooLong",
                   "workflow_feedback": "File is too large. Draft files are limited to 256 KiB total."}
        module.assert_oversized_attachment_refusal(before, current, current["workflow_path"], "draft", 256 * 1024)
        with self.assertRaises(module.DriverError):
            module.assert_oversized_attachment_refusal(before, {**current, "attachment_count": 1},
                                                       current["workflow_path"], "draft", 256 * 1024)

    def test_send_blocked_by_attachment_requires_disabled_painted_target(self):
        module = load_cli()
        value = {"attachment_count": 1, "send_disabled_reason": "Attachments are local only. Remove them before Send.",
                 "targets": [{"id": "command.send", "enabled": False, "pointer_bounds": [1, 2, 3, 4]}]}
        module.assert_send_blocked_by_attachment(value)
        with self.assertRaises(module.DriverError):
            module.assert_send_blocked_by_attachment({**value, "attachment_count": 0})
        with self.assertRaises(module.DriverError):
            module.assert_send_blocked_by_attachment({**value, "targets": [{"id": "command.send", "enabled": True,
                                                                              "pointer_bounds": [1, 2, 3, 4]}]})

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
                    patch.object(module, "bind_process") as bind, \
                    patch.object(module, "wait_snapshot", return_value=before):
                module.restart_app(session, argparse.Namespace(timeout=1, quit_after_ms=1000))
            close.assert_called_once_with(session, 1, clean_desktop=False)
            bind.assert_called_once()
            self.assertEqual(bind.call_args.args[1], 101)
            self.assertEqual(session.data["launch"]["pid"], 101)
            self.assertEqual(session.observations, output / "restart-process" / "live.json")
            self.assertEqual(session.data["actions"][0]["action"], "scenario.restart")


if __name__ == "__main__":
    unittest.main()
