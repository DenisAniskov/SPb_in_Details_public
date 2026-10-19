#!/usr/bin/env python3
"""Report Dart formatting drift for the files a change actually touches.

Dart 3.13 formats with the "tall style", which the codebase predates: a
repository-wide `dart format --set-exit-if-changed` would rewrite 70+ files,
including the generated scenic dataset, and a release-source import must not
carry a mass reformat. This check therefore looks only at Dart files changed
against the base revision and reports them, so new code stays formatted without
rewriting existing files.

Advisory by default (exit 0). Pass --strict to fail on drift; CI keeps the
advisory mode and prints the same list.

Usage:
  python tool/check_changed_dart_format.py [--base <git-ref>] [--strict]
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True, text=True, check=False
    )


def resolve_base(explicit: str | None) -> str | None:
    candidates = [explicit] if explicit else []
    for variable in ("CHECK_FORMAT_BASE", "GITHUB_BASE_REF", "GITHUB_EVENT_BEFORE"):
        value = os.environ.get(variable)
        if not value or set(value) == {"0"}:
            continue
        candidates.append(f"origin/{value}" if variable == "GITHUB_BASE_REF" else value)
    candidates += ["origin/main", "HEAD~1"]

    for candidate in candidates:
        if git("rev-parse", "--verify", "--quiet", candidate).returncode == 0:
            return candidate
    return None


def dart_executable() -> str | None:
    return shutil.which("dart")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base")
    parser.add_argument("--strict", action="store_true")
    arguments = parser.parse_args()

    if not (ROOT / ".git").exists():
        print("not a Git work tree: skipping the formatting report")
        return 0

    base = resolve_base(arguments.base)
    if base is None:
        print("no base revision available: skipping the formatting report")
        return 0

    diff = git("diff", "--name-only", "--diff-filter=ACMR", base, "HEAD", "--", "*.dart")
    if diff.returncode != 0:
        print(f"could not diff against {base}: {diff.stderr.strip()}")
        return 0

    files = [line for line in diff.stdout.splitlines() if line.strip()]
    files = [name for name in files if (ROOT / name).is_file()]
    if not files:
        print(f"no changed Dart files against {base}: nothing to check")
        return 0

    dart = dart_executable()
    if dart is None:
        print(f"{len(files)} changed Dart file(s) against {base}; dart not found, skipped")
        return 0

    print(f"changed Dart files against {base}: {len(files)}")
    result = subprocess.run(
        [dart, "format", "--output=none", "--set-exit-if-changed", *files],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    output = (result.stdout + result.stderr).strip()
    if output:
        print(output)
    if result.returncode == 0:
        print("formatting: no drift in changed files")
        return 0

    print(
        "formatting: drift in changed files\n"
        "  Fix with: dart format <files>\n"
        "  Existing files predate the Dart 3.13 formatter and are intentionally "
        "not reformatted in bulk."
    )
    return 1 if arguments.strict else 0


if __name__ == "__main__":
    sys.exit(main())
