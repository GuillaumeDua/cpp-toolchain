#!/usr/bin/env python3
"""Assert every third-party GitHub Action is pinned to a commit digest, carrying the tag it was pinned from.

Invariants:

- nothing floats

    `uses: owner/action@v4` is a mutable tag whose owner can repoint it at any commit,
    which is what happened to tj-actions/changed-files in March 2025 (CVE-2025-30066).
    docker-publish.yml runs with the Docker Hub token, RELEASE_PR_TOKEN and `packages: write` in scope.

- nothing is opaque

    A bare 40-hex sha says nothing to a reviewer,
    so the tag it resolved from rides along as a trailing comment.

`helpers:pinGitHubActionDigestsToSemver` in renovate.json produces both, so this asserts the tree still
looks like Renovate's output rather than enforcing a second convention. The comment is deliberately not
matched against a version shape: what it should say is Renovate's to decide.

Local `./.github/actions/...` references are exempt: they resolve to the commit under test, which is already exact.

Lines are matched with a regex rather than parsed as YAML, because an error here is only actionable with a line
number and safe_load discards them.

Usage, from the repository root - both defaults are paths relative to it:
    python3 scripts/details/check-action-pins.py [--workflows .github/workflows] [--actions .github/actions]

Exits non-zero and reports every violation it found, rather than only the first.
"""

import argparse
import os
import pathlib
import re
import sys

# A step's `uses:`, with or without the list dash, and with the digest pin's trailing `# <tag>` if present.
USES = re.compile(r"^\s*(?:-\s*)?uses:\s*(?P<ref>\S+)(?:\s+#\s*(?P<tag>\S+))?\s*$")

PINNED = re.compile(r"^(?P<action>[^@]+)@[0-9a-f]{40}$")


def check(path):
    """([(lineno, message)], pinned count) for one workflow or composite action file."""
    problems = []
    pinned = 0

    for lineno, line in enumerate(path.read_text(encoding="utf-8").split("\n"), start=1):
        match = USES.match(line)
        if not match:
            continue

        ref = match.group("ref")
        if ref.startswith("./"):
            continue

        if not PINNED.match(ref):
            action, _, tag = ref.partition("@")
            problems.append((
                lineno,
                f"{ref} is a mutable tag - pin it to the commit it resolves to today: "
                f"gh api repos/{action}/commits/{tag or '<tag>'} --jq .sha",
            ))
            continue

        if not match.group("tag"):
            problems.append((
                lineno,
                f"{ref} carries no version comment - append `# <version>`, "
                f"the form helpers:pinGitHubActionDigestsToSemver writes and what makes the sha reviewable",
            ))
            continue

        pinned += 1

    return problems, pinned


def sources(workflows, actions):
    """Every file a `uses:` can appear in, in a stable order. A missing directory contributes nothing."""
    for directory, pattern in ((workflows, "*.y*ml"), (actions, "*/action.y*ml")):
        yield from sorted(directory.glob(pattern))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--workflows", default=".github/workflows", type=pathlib.Path)
    parser.add_argument("--actions", default=".github/actions", type=pathlib.Path)
    args = parser.parse_args()

    # Annotations render inline on the diff under Actions; plain text is more readable in a terminal.
    on_actions = bool(os.environ.get("GITHUB_ACTIONS"))

    violations = 0
    pinned = 0
    files = 0

    for path in sources(args.workflows, args.actions):
        files += 1
        problems, found = check(path)
        pinned += found
        for lineno, message in problems:
            if on_actions:
                print(f"::error file={path},line={lineno}::{message}")
            else:
                print(f"{path}:{lineno}: error: {message}", file=sys.stderr)
            violations += 1

    if violations:
        return 1

    print(f"{pinned} action ref(s) pinned to a digest across {files} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
