#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HOOK = Path(__file__).resolve().parents[1] / "pre-push.py"
ZERO = "0" * 40


class PushSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.root / "README.md").write_text("Fixture\n")
        self.base = self.commit("base")
        self.git("update-ref", "refs/remotes/origin/main", self.base)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.DEVNULL).decode().strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-m", message)
        return self.git("rev-parse", "HEAD")

    def push(self, head, previous=ZERO):
        return subprocess.run([sys.executable, "-B", str(HOOK), "origin"], cwd=self.root,
                              input=f"refs/heads/task {head} refs/heads/task {previous}\n", text=True, capture_output=True)

    def test_invalid_committed_swift_cannot_hide_behind_a_fixed_worktree(self):
        source = self.root / "example.swift"
        source.write_text("let broken =\n")
        head = self.commit("broken")
        source.write_text("let fixed = 1\n")
        self.assertNotEqual(self.push(head).returncode, 0)

    def test_only_pushed_snapshot_is_checked(self):
        source = self.root / "example.swift"
        source.write_text("let value = 1\n")
        head = self.commit("valid")
        source.write_text("let broken =\n")
        result = self.push(head, self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 changed Swift files parsed", result.stdout)

    def test_missing_remote_commit_expands_validation(self):
        (self.root / "example.swift").write_text("let broken =\n")
        self.assertNotEqual(self.push(self.commit("broken"), "f" * 40).returncode, 0)

    def test_whitespace_errors_block_and_deletion_has_no_source(self):
        (self.root / "README.md").write_text("Trailing space \n")
        self.assertNotEqual(self.push(self.commit("whitespace")).returncode, 0)
        self.assertEqual(self.push(ZERO, self.base).returncode, 0)


if __name__ == "__main__":
    unittest.main()
