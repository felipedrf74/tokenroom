#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
current="$(git config --get core.hooksPath || true)"
if [[ -n "$current" && "$current" != '.githooks' ]]; then
  printf 'An existing hooksPath is configured (%s); integrate the pre-push hook there.\n' "$current" >&2
  exit 1
fi
if [[ -z "$current" && -e "$(git rev-parse --git-path hooks/pre-push)" ]]; then
  printf 'An existing pre-push hook is installed; integrate .githooks/pre-push there.\n' >&2
  exit 1
fi
git config --local core.hooksPath .githooks
printf 'Pre-push hook enabled for this repository and its worktrees.\n'
