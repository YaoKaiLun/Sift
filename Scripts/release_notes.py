#!/usr/bin/env python3
import os
import re
import subprocess
import sys


_COMMIT = re.compile(
    r"^(feat|improve|fix)(?:\([^)]*\))?!?:\s*(.+)$"
)
_CATEGORIES = (
    ("feat", "新增功能"),
    ("improve", "体验改进"),
    ("fix", "问题修复"),
)


def generate_release_notes(subjects):
    grouped = {kind: [] for kind, _ in _CATEGORIES}
    for subject in subjects:
        match = _COMMIT.fullmatch(subject.strip())
        if match:
            grouped[match.group(1)].append(match.group(2))

    sections = []
    for kind, title in _CATEGORIES:
        items = grouped[kind]
        if items:
            sections.append(
                f"## {title}\n\n" + "\n".join(f"- {item}" for item in items)
            )
    return "\n\n".join(sections) + ("\n" if sections else "")


def previous_tag(current_tag):
    result = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0", f"{current_tag}^"],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def commit_subjects(current_tag):
    previous = previous_tag(current_tag)
    revision = f"{previous}..{current_tag}" if previous else current_tag
    output = subprocess.check_output(
        ["git", "log", "--format=%s", "--reverse", revision],
        text=True,
    )
    return output.splitlines()


def main():
    current_tag = (
        sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GITHUB_REF_NAME")
    )
    if not current_tag:
        raise SystemExit("usage: release_notes.py <current-tag>")
    sys.stdout.write(generate_release_notes(commit_subjects(current_tag)))


if __name__ == "__main__":
    main()
