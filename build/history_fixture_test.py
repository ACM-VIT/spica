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
