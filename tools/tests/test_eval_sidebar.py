#!/usr/bin/env python3
"""Offline integrity checks for the native sidebar evidence assertions."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


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
            self.assertFalse(output.exists())

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


if __name__ == "__main__":
    unittest.main()
