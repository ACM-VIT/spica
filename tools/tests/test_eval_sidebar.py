#!/usr/bin/env python3
"""Offline integrity checks for the native sidebar evidence assertions."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "tools/eval-sidebar"
LOADER = importlib.machinery.SourceFileLoader("eval_sidebar", str(CLI))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SidebarEvidenceTests(unittest.TestCase):
    def test_dry_run_cannot_create_state_or_launch_a_desktop(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "unused"
            result = subprocess.run(["python3", str(CLI), "--dry-run", "--output", str(output)],
                                    cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["build"], False)
            self.assertEqual(json.loads(result.stdout)["fixture_lifetime_ms"], 1_800_000)
            self.assertFalse(output.exists())

    def test_clipboard_daemon_stdio_is_detached_with_bounded_parent_timeout(self):
        environment = {"WAYLAND_DISPLAY": "owned", "XDG_RUNTIME_DIR": "/private/runtime"}
        with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            MODULE.publish_clipboard(environment, "café 世界", 20)
        self.assertEqual(run.call_args.args[0], ["wl-copy", "--", "café 世界"])
        self.assertEqual(run.call_args.kwargs["env"], environment)
        for field in ("stdin", "stdout", "stderr"):
            self.assertEqual(run.call_args.kwargs[field], subprocess.DEVNULL)
        self.assertEqual(run.call_args.kwargs["timeout"], 20)
        self.assertTrue(run.call_args.kwargs["start_new_session"])
        with patch.object(MODULE.subprocess, "run", side_effect=subprocess.TimeoutExpired([], 20)):
            with self.assertRaisesRegex(ValueError, "publication timed out"):
                MODULE.publish_clipboard(environment, "private fixture", 20)
        with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaisesRegex(ValueError, "publisher failed"):
                MODULE.publish_clipboard(environment, "private fixture", 20)

    def test_missing_duplicate_or_misaligned_metadata_cannot_pass(self):
        value = {"thread_targets": [{"id": "alpha"}, {"id": "bravo"}],
                 "thread_pinned": [True, False], "thread_settled": [False, True],
                 "thread_snoozed_until": [0, 0], "thread_sort_order": [1, 2]}
        self.assertEqual(MODULE.rows(value)["bravo"]["settled"], True)
        for changed in ({"thread_pinned": []}, {"thread_settled": None},
                        {"thread_targets": [{"id": "alpha"}, {"id": "alpha"}]}):
            with self.assertRaises(ValueError):
                MODULE.rows({**value, **changed})

    def test_wrong_target_run_command_or_draft_fails_retention(self):
        value = {"thread_id": "thread", "project_id": "project", "run_id": "run",
                 "send_command_id": "command", "send_run_id": "run", "draft": "café 世界"}
        MODULE.assert_retained(value, value, value["draft"])
        for field in value:
            with self.assertRaises(ValueError):
                MODULE.assert_retained(value, {**value, field: "changed"}, value["draft"])

    def test_resident_count_excludes_disabled_placeholder_slots(self):
        value = {"thread_count": 1,
                 "thread_targets": [{"id": "alpha"}, {"id": "window.close"}, {"id": "window.close"}],
                 "thread_pinned": [True, False, False], "thread_settled": [False] * 3,
                 "thread_snoozed_until": [0] * 3, "thread_sort_order": [0] * 3}
        self.assertEqual(set(MODULE.rows(value)), {"alpha"})
        for count in (-1, 4, True):
            with self.assertRaises(ValueError):
                MODULE.rows({**value, "thread_count": count})

    def test_compact_geometry_rejects_cards_overlap_and_wrong_identity(self):
        target = lambda identifier, y, height=36: {"id": identifier, "enabled": True,
                                                   "pointer_bounds": [8, y, 240, height]}
        snapshot = {"thread_targets": [target("alpha", 96), target("bravo", 133)]}
        MODULE.assert_compact(snapshot, {"alpha", "bravo"})
        for changed in ([target("alpha", 96, 78), target("bravo", 178)],
                        [target("alpha", 96), target("bravo", 100)],
                        [target("alpha", 96), target("other", 133)]):
            with self.assertRaises(ValueError):
                MODULE.assert_compact({"thread_targets": changed}, {"alpha", "bravo"})

    def test_overlay_rejects_any_enabled_covered_thread(self):
        MODULE.assert_suppressed({"thread_targets": [{"enabled": False}]})
        with self.assertRaises(ValueError):
            MODULE.assert_suppressed({"thread_targets": [{"enabled": True}]})

    def test_editor_requires_exact_text_and_observation_presence(self):
        expected = "Ae\u0301👩‍💻B"
        MODULE.assert_editor({"sidebar_search": expected}, "sidebar_search", expected)
        for snapshot in ({}, {"sidebar_search": "Aé👩‍💻B"}, {"sidebar_search": "Ae\u0301B"}):
            with self.assertRaises(ValueError):
                MODULE.assert_editor(snapshot, "sidebar_search", expected)

    def test_preferences_cannot_omit_fields_or_accept_invalid_widths_and_shelves(self):
        value = {"sidebar_collapsed": True, "sidebar_width_override": 316,
                 "sidebar_working_shelf": False, "sidebar_shelf_expanded": [False, True, True],
                 "sidebar_scope_project": "project"}
        self.assertEqual(MODULE.preferences(value), value)
        for field in value:
            with self.assertRaises(ValueError):
                MODULE.preferences({key: item for key, item in value.items() if key != field})
        for changed in ({"sidebar_width_override": float("nan")}, {"sidebar_width_override": True},
                        {"sidebar_width_override": 207}, {"sidebar_shelf_expanded": [False]},
                        {"sidebar_shelf_expanded": [0, True, True]}, {"sidebar_collapsed": 1}):
            with self.assertRaises(ValueError):
                MODULE.preferences({**value, **changed})

    def test_restart_retention_rejects_any_preference_or_route_change(self):
        value = {"sidebar_collapsed": True, "sidebar_width_override": 316,
                 "sidebar_working_shelf": False, "sidebar_shelf_expanded": [False, True, True],
                 "sidebar_scope_project": "project", "project_id": "project", "thread_id": "thread", "run_id": "run"}
        MODULE.assert_preferences(value, value)
        for field, changed in (("sidebar_collapsed", False), ("sidebar_width_override", 256),
                               ("sidebar_working_shelf", True), ("sidebar_shelf_expanded", [False] * 3),
                               ("sidebar_scope_project", ""), ("project_id", "other-project"),
                               ("thread_id", "other-thread"), ("run_id", "other-run")):
            with self.assertRaises(ValueError):
                MODULE.assert_preferences(value, {**value, field: changed})


if __name__ == "__main__":
    unittest.main()
