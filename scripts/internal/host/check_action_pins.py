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

- nothing disagrees

    One repository, one digest.
    `actions/cache` and `actions/cache/restore` are the same repository,
    so a ref that stops being updated leaves two versions of one action in the tree,
    which neither site shows on its own.

`helpers:pinGitHubActionDigestsToSemver` in renovate.json produces the first two, so they assert the tree
still looks like Renovate's output rather than enforcing a second convention.
The comment is deliberately not matched against a version shape: what it should say is Renovate's to decide.
The third is this repository's own: the github-actions manager documents the subdirectory form with a tag
rather than with a digest, so whether Renovate moves a digest-pinned subpath is not something to assume.

Local `./.github/actions/...` references are exempt: they resolve to the commit under test, which is already exact.

Lines are matched with a regex rather than parsed as YAML, because an error here is only actionable with a line
number and safe_load discards them.

Usage, from the repository root - both defaults are paths relative to it:
    python3 scripts/internal/host/check_action_pins.py [--workflows .github/workflows] [--actions .github/actions]

Exits non-zero and reports every violation it found, rather than only the first.
"""

import argparse
import os
import pathlib
import re
import sys

# A step's `uses:`, with or without the list dash, and with the digest pin's trailing `# <tag>` if present.
USES = re.compile(r"^\s*(?:-\s*)?uses:\s*(?P<ref>\S+)(?:\s+#\s*(?P<tag>\S+))?\s*$")

PINNED = re.compile(r"^(?P<action>[^@]+)@(?P<digest>[0-9a-f]{40})$")


def repository(action):
    """The repository an action path belongs to, which is what carries the digest."""
    return "/".join(action.split("/")[:2])


def check(path):
    """([(lineno, message)], [(lineno, ref, repository, digest)]) for one workflow or composite action file."""
    problems = []
    pins = []

    for lineno, line in enumerate(path.read_text(encoding="utf-8").split("\n"), start=1):
        match = USES.match(line)
        if not match:
            continue

        ref = match.group("ref")
        if ref.startswith("./"):
            continue

        pin = PINNED.match(ref)
        if not pin:
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

        pins.append((lineno, ref, repository(pin.group("action")), pin.group("digest")))

    return problems, pins


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

    def report(path, lineno, message):
        if on_actions:
            print(f"::error file={path},line={lineno}::{message}")
        else:
            print(f"{path}:{lineno}: error: {message}", file=sys.stderr)

    violations = 0
    pinned = 0
    files = 0
    # <repository> -> <digest> -> [(path, lineno, ref)], which the last invariant reads across files.
    digests = {}

    for path in sources(args.workflows, args.actions):
        files += 1
        problems, pins = check(path)
        pinned += len(pins)
        for lineno, ref, repo, digest in pins:
            digests.setdefault(repo, {}).setdefault(digest, []).append((path, lineno, ref))
        for lineno, message in problems:
            report(path, lineno, message)
            violations += 1

    for repo, by_digest in sorted(digests.items()):
        if len(by_digest) == 1:
            continue
        for digest, locations in sorted(by_digest.items()):
            others = sorted(other[:12] for other in by_digest if other != digest)
            for path, lineno, ref in locations:
                report(path, lineno,
                       f"{ref} pins {repo} at {digest[:12]}, and it is also pinned at "
                       f"{', '.join(others)} - one repository carries one digest")
                violations += 1

    if violations:
        return 1

    print(f"{pinned} action ref(s) pinned to a digest across {files} file(s), "
          f"{len(digests)} repositories at one digest each")
    return 0


if __name__ == "__main__":
    sys.exit(main())
