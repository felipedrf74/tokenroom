#!/usr/bin/env python3
"""Only an explicit prose-only diff may skip Apple builds."""
import os
from pathlib import PurePosixPath
import re
import subprocess


def requires_build(files):
    def prose(name):
        path = PurePosixPath(name)
        return name in {"README.md", "CHANGELOG.md"} or (
            path.parts[0] == "docs" and path.suffix == ".md"
            and not any(part.startswith(".") for part in path.parts)
        )

    return not files or not all(prose(name) for name in files)


def classify(event, base):
    if event not in {"pull_request", "push"} or not re.fullmatch(r"[0-9a-f]{40}", base) or base == "0" * 40:
        return True
    # No rename detection: both sides of a move must be documentation.
    diff = subprocess.check_output([
        "git", "diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", base, "HEAD", "--",
    ])
    return requires_build([name.decode("utf-8") for name in diff.split(b"\0") if name])


if __name__ == "__main__":
    required = str(classify(os.environ.get("GITHUB_EVENT_NAME", ""), os.environ.get("CHANGE_BASE", ""))).lower()
    print(f"build_required={required}")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"build_required={required}\n")
