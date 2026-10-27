#!/usr/bin/env python3
"""Small public-Host integration check for build-history-fixture."""
import json
import os
import pathlib
import sqlite3
import subprocess
import tempfile
import unittest


class HistoryFixtureTest(unittest.TestCase):
    def invoke(self, root, *, turns=1, content=96, name="boundary", extra=()):
        return subprocess.run([str(pathlib.Path("zig-out/bin/build-history-fixture").resolve()),
            "--state", str(root / "state"), "--workspace", str(root / "workspace"),
            "--threads", "1", "--turns", str(turns), "--content-bytes", str(content),
            "--seed", "17", "--name", name, *extra], text=True, capture_output=True, timeout=45)

    def test_deep_history_pages_and_late_cancellation(self):
        with tempfile.TemporaryDirectory(prefix="spica-history-deep-") as directory:
            root = pathlib.Path(directory)
            result = self.invoke(root, turns=130, extra=("--cancel-last",))
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads(result.stdout)
            self.assertEqual(manifest["completed_runs"], 129)
            self.assertEqual(manifest["cancelled_runs"], 1)
            self.assertEqual(manifest["generated_messages"], 260)
            with sqlite3.connect((root / "state/conversation.sqlite3").as_uri() + "?mode=ro", uri=True) as db:
                self.assertEqual(db.execute("SELECT state FROM runs WHERE id=?", (manifest["latest_run_id"],)).fetchone()[0], "cancelled")
                self.assertEqual(db.execute("SELECT sum(length(bytes)) FROM chunks").fetchone()[0], manifest["content_bytes"])
                self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")

    def test_exact_prompt_limit_and_unicode_header_truncation(self):
        for length in (26, 27, 28, 29, 65536):
            with self.subTest(length=length), tempfile.TemporaryDirectory(prefix="spica-history-unicode-") as directory:
                root = pathlib.Path(directory)
                result = self.invoke(root, content=length, name="🎮 日本語")
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest = json.loads(result.stdout)
                self.assertEqual(manifest["prompt_bytes"], length)
                with sqlite3.connect((root / "state/conversation.sqlite3").as_uri() + "?mode=ro", uri=True) as db:
                    self.assertEqual(db.execute("SELECT sum(length(bytes)) FROM chunks").fetchone()[0], manifest["content_bytes"])

    def test_symlink_roots_are_refused_before_creating_database(self):
        for target in ("state", "workspace"):
            with self.subTest(target=target), tempfile.TemporaryDirectory(prefix="spica-history-symlink-") as directory:
                root = pathlib.Path(directory)
                actual = root / "actual"
                actual.mkdir()
                (root / target).symlink_to(actual, target_is_directory=True)
                result = self.invoke(root)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(actual.iterdir()), [])
                self.assertFalse((root / "state/conversation.sqlite3").exists())

    def test_git_is_initialized_before_durable_workspace_capture(self):
        with tempfile.TemporaryDirectory(prefix="spica-history-git-") as directory:
            root = pathlib.Path(directory)
            result = self.invoke(root, extra=("--git-init",))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(json.loads(result.stdout)["provenance"]["git_initialized"])
            workspace = root / "workspace"
            self.assertTrue((workspace / ".git").is_dir())
            top = subprocess.run(["git", "-C", str(workspace), "rev-parse", "--show-toplevel"],
                                 check=True, text=True, capture_output=True).stdout.strip()
            self.assertEqual(top, str(workspace))
            with sqlite3.connect((root / "state/conversation.sqlite3").as_uri() + "?mode=ro", uri=True) as db:
                binding = json.loads(db.execute("SELECT binding FROM workspaces").fetchone()[0])
                self.assertFalse(binding["non_git"])
                self.assertEqual(binding["canonical_root"], str(workspace))
                self.assertEqual(binding["repository_identity"], str(workspace / ".git"))

    def test_generates_and_rejects_reuse(self):
        executable = pathlib.Path("zig-out/bin/build-history-fixture").resolve()
        self.assertTrue(executable.is_file(), executable)
        with tempfile.TemporaryDirectory(prefix="spica-history-test-") as root:
            root_path = pathlib.Path(root)
            state = root_path / "state"
            workspace = root_path / "workspace"
            command = [
                str(executable),
                "--state", str(state),
                "--workspace", str(workspace),
                "--threads", "2",
                "--turns", "3",
                "--content-bytes", "96",
                "--seed", "17",
                "--name", "python-check",
                "--cancel-last",
            ]
            completed = subprocess.run(command, check=True, text=True, capture_output=True, timeout=30)
            self.assertLess(len(completed.stdout), 16 * 1024)
            manifest = json.loads(completed.stdout)
            self.assertEqual(manifest["fixture"], "synthetic-large-history")
            self.assertEqual(manifest["generated_threads"], 2)
            self.assertEqual(manifest["generated_turns"], 6)
            self.assertEqual(manifest["generated_runs"], 6)
            self.assertEqual(manifest["generated_messages"], 12)
            self.assertEqual(manifest["completed_runs"], 5)
            self.assertEqual(manifest["cancelled_runs"], 1)
            self.assertEqual(manifest["prompt_bytes"], 6 * 96)
            self.assertGreater(manifest["content_bytes"], manifest["prompt_bytes"])
            self.assertEqual(pathlib.Path(manifest["state_path"]), state.resolve())
            self.assertEqual(pathlib.Path(manifest["workspace_path"]), workspace.resolve())

            database = state / "conversation.sqlite3"
            self.assertTrue(database.is_file())
            connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
            try:
                self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone()[0], "ok")
                self.assertEqual(connection.execute("PRAGMA foreign_key_check").fetchall(), [])
                self.assertEqual(connection.execute("SELECT count(*) FROM projects").fetchone()[0], 1)
                self.assertEqual(connection.execute("SELECT count(*) FROM workspaces").fetchone()[0], 1)
                self.assertEqual(connection.execute("SELECT count(*) FROM threads").fetchone()[0], 2)
                self.assertEqual(connection.execute("SELECT count(*) FROM runs").fetchone()[0], 6)
                self.assertEqual(connection.execute("SELECT count(*) FROM messages").fetchone()[0], 12)
                self.assertEqual(connection.execute("SELECT count(*) FROM runs WHERE state='cancelled'").fetchone()[0], 1)
                latest = connection.execute("SELECT 1 FROM threads WHERE id=?", (manifest["latest_thread_id"],)).fetchone()
                self.assertIsNotNone(latest)
                latest_block = connection.execute("SELECT 1 FROM blocks WHERE id=?", (manifest["latest_assistant_block_id"],)).fetchone()
                self.assertIsNotNone(latest_block)
            finally:
                connection.close()

            reused = subprocess.run(command, text=True, capture_output=True, timeout=30)
            self.assertNotEqual(reused.returncode, 0)


if __name__ == "__main__":
    unittest.main()
