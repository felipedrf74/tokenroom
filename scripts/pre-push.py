#!/usr/bin/env python3
"""Check whitespace and Swift syntax in the commits being pushed, not the worktree.

Module typechecking remains in CI: parsing an isolated file cannot establish
Swift's cross-file types. No compiler diagnostic or timeout is treated as a pass.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ZERO = "0" * 40


def git(*args):
    return subprocess.check_output(["git", *args])


def check_updates(lines, remote):
    for line in lines:
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) != 4 or not all(re.fullmatch(r"[0-9a-f]{40}", value) for value in (fields[1], fields[3])):
            raise ValueError("Malformed pre-push ref update")
        _, local, _, previous = fields
        if local == ZERO:
            continue
        head = git("rev-parse", "--verify", local + "^{commit}").decode().strip()
        if previous == ZERO:
            base = subprocess.run(["git", "merge-base", head, f"refs/remotes/{remote}/main"], capture_output=True)
            previous = base.stdout.decode().strip() if base.returncode == 0 else ""
        available = subprocess.run(["git", "cat-file", "-e", previous + "^{commit}"], capture_output=True) if previous else None
        if available is None or available.returncode:
            # A missing remote object must expand the check, never hide files.
            previous = subprocess.check_output(["git", "hash-object", "-t", "tree", "--stdin"], input=b"").decode().strip()
        subprocess.run(["git", "diff", "--no-ext-diff", "--check", previous, head, "--"], check=True)
        names = git("diff", "--no-ext-diff", "--no-renames", "--name-only", "--diff-filter=ACMRT", "-z", previous, head, "--")
        swift = [name.decode() for name in names.split(b"\0") if name.endswith(b".swift")]
        with tempfile.TemporaryDirectory(prefix="swift-pre-push-") as directory:
            for index, name in enumerate(swift):
                source = Path(directory) / f"source-{index}.swift"
                source.write_bytes(git("show", f"{head}:{name}"))
                print(f"Swift syntax: {name}", flush=True)
                subprocess.run(["xcrun", "swiftc", "-frontend", "-parse", str(source)], check=True)
        print(f"Pre-push: whitespace checked; {len(swift)} changed Swift files parsed. Semantic typechecking remains in CI.", flush=True)


if __name__ == "__main__":
    # The hook runs from the repository root. Do not let inherited git overrides
    # redirect validation to an unrelated index, worktree or object store.
    for key in list(os.environ):
        if key.startswith("GIT_"):
            del os.environ[key]
    os.environ["GIT_NO_REPLACE_OBJECTS"] = "1"
    check_updates(sys.stdin, sys.argv[1])
