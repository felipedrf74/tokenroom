#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ci_changes", Path(__file__).resolve().parents[1] / "ci-changes.py")
changes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changes)


class ChangeSelectionTests(unittest.TestCase):
    def test_only_explicit_prose_can_skip(self):
        self.assertFalse(changes.requires_build(["README.md", "CHANGELOG.md", "docs/guide.md"]))
        for name in ["docs/hidden.swift", "docs/run.sh", "docs/.hidden.md", "docs/config.json", "Config/App.xcconfig", ".github/workflows/ci.yml", "Shared/a.swift", "unknown", "docs/README.md.swift"]:
            with self.subTest(name=name):
                self.assertTrue(changes.requires_build(["README.md", name]))

    def test_empty_diff_unknown_base_and_nightly_run_everything(self):
        self.assertTrue(changes.requires_build([]))
        for event, base in [("schedule", "a" * 40), ("workflow_dispatch", "a" * 40), ("push", "0" * 40), ("pull_request", "")]:
            self.assertTrue(changes.classify(event, base))

    def test_rename_and_deleted_code_cannot_hide_behind_docs(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], stderr=subprocess.DEVNULL).decode().strip()
            git("init")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            source = Path(directory) / "source.swift"
            source.write_text("let value = 1\n")
            git("add", ".")
            git("commit", "-m", "base")
            base = git("rev-parse", "HEAD")
            source.rename(Path(directory) / "README.md")
            git("add", "-A")
            git("commit", "-m", "rename")
            original = subprocess.check_output
            with patch.object(changes.subprocess, "check_output", side_effect=lambda args: original(args, cwd=directory)):
                self.assertTrue(changes.classify("pull_request", base))


if __name__ == "__main__":
    unittest.main()
