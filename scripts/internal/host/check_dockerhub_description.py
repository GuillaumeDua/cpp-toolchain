#!/usr/bin/env python3
"""Assert the Docker Hub repository description fits what Docker Hub accepts.

`.github/dockerhub/` is the source of truth for the two texts on the Docker Hub repository page, and
.github/workflows/dockerhub-description.yml syncs them to it on a merge to `main`.

Every invariant here is one Docker Hub breaks silently:

- both texts are truncated past their limits, which peter-evans/dockerhub-description reports as a
  warning rather than an error, so an over-long line reaches the page cut rather than failing the run.
  The limits are in bytes, not characters.

- a relative link target resolves against hub.docker.com, landing on a page that does not exist.
  The action's `enable-url-completion` rewrites relative targets in inline links, but it rewrites the
  ones inside code blocks too and leaves reference definitions alone, so the sync leaves it off and
  every target is absolute instead.

- GitHub alert blocks (`> [!NOTE]`) are GitHub-flavored markdown: Docker Hub prints the `[!NOTE]` literally.

- an empty text goes out unchecked. The action's one PATCH always carries `full_description`, so an
  empty `description.md` publishes a blank page, and drops `description` when it is falsy, so an empty
  `short-description.txt` leaves whatever the page already says, which the repository then contradicts.

The build gate runs this on every pull request (.github/workflows/docker-build.yml), so a violation
fails the pull request that introduces it rather than reaching the sync.

Usage, from the repository root - the default is a path relative to it:
    python3 scripts/internal/host/check_dockerhub_description.py [--directory .github/dockerhub]
    python3 scripts/internal/host/check_dockerhub_description.py --print-short

`--print-short` emits the `short=<line>` the sync workflow appends to `GITHUB_OUTPUT`, and runs the
asserts first, so that path cannot hand the action a value this script rejects.

Exits non-zero and reports every violation it found, rather than only the first.
"""

import argparse
import os
import pathlib
import re
import sys

SHORT_DESCRIPTION = "short-description.txt"
DESCRIPTION = "description.md"

SHORT_DESCRIPTION_LIMIT = 100
DESCRIPTION_LIMIT = 25000

# A markdown inline link or image, capturing what it points at.
LINK = re.compile(r"!?\[[^\]]*\]\((?P<target>[^)]*)\)")

# A link reference definition, `[label]: target`, which carries a target the inline form's regex never sees.
REFERENCE = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(?P<target>\S+)")

ALERT = re.compile(r"^\s*>\s*\[!(?P<kind>[A-Z]+)\]")

ABSOLUTE = ("https://", "http://")


def read(path):
    """(the file's bytes, [(lineno, message)]) - bytes are None when there is nothing publishable to check."""
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return None, [(1, "no such file - the sync has nothing to publish from it")]

    if not raw.strip():
        return None, [(1, "the file is empty - the sync has nothing to publish from it")]

    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as error:
        return None, [(1, f"the file is not UTF-8, which is what Docker Hub serves: {error}")]

    return raw, []


def check_short_description(path):
    """([(lineno, message)], the line itself or None, its size) for the one-line field under the title."""
    raw, problems = read(path)
    if raw is None:
        return problems, None, 0

    text = raw[:-1] if raw.endswith(b"\n") else raw

    if b"\n" in text:
        return [(1, "the short description is one field, so it has to be one line")], None, len(text)

    if len(text) > SHORT_DESCRIPTION_LIMIT:
        return [(
            1,
            f"the short description is {len(text)} bytes - Docker Hub keeps "
            f"{SHORT_DESCRIPTION_LIMIT} and truncates the rest away",
        )], None, len(text)

    return [], text.decode("utf-8"), len(text)


def check_description(path):
    """([(lineno, message)], absolute link count, size) for the page body."""
    raw, problems = read(path)
    if raw is None:
        return problems, 0, 0

    links = 0

    if len(raw) > DESCRIPTION_LIMIT:
        problems.append((
            1,
            f"the description is {len(raw)} bytes - Docker Hub keeps "
            f"{DESCRIPTION_LIMIT} and truncates the rest away",
        ))

    for lineno, line in enumerate(raw.decode("utf-8").split("\n"), start=1):
        alert = ALERT.match(line)
        if alert:
            problems.append((
                lineno,
                f"`[!{alert.group('kind')}]` is a GitHub alert block - Docker Hub prints it literally, "
                f"so write the note as prose",
            ))

        reference = REFERENCE.match(line)
        targets = [match.group("target") for match in LINK.finditer(line)]
        if reference:
            targets.append(reference.group("target"))

        for target in targets:
            if target.startswith(ABSOLUTE):
                links += 1
                continue
            problems.append((
                lineno,
                f"`{target}` is not an absolute URL - Docker Hub resolves it against hub.docker.com",
            ))

    return problems, links, len(raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--directory", default=".github/dockerhub", type=pathlib.Path)
    parser.add_argument("--print-short", action="store_true",
                        help="emit `short=<line>` for GITHUB_OUTPUT instead of the summary")
    args = parser.parse_args()

    short_path = args.directory / SHORT_DESCRIPTION
    description_path = args.directory / DESCRIPTION

    short_problems, short, short_size = check_short_description(short_path)
    description_problems, links, description_size = check_description(description_path)

    # Annotations render inline on the diff under Actions; plain text is more readable in a terminal.
    on_actions = bool(os.environ.get("GITHUB_ACTIONS"))

    violations = 0
    for path, problems in ((short_path, short_problems), (description_path, description_problems)):
        for lineno, message in problems:
            if on_actions:
                print(f"::error file={path},line={lineno}::{message}")
            else:
                print(f"{path}:{lineno}: error: {message}", file=sys.stderr)
            violations += 1

    if violations:
        return 1

    if args.print_short:
        print(f"short={short}")
        return 0

    print(f"short description {short_size}/{SHORT_DESCRIPTION_LIMIT} bytes, "
          f"description {description_size}/{DESCRIPTION_LIMIT} bytes, "
          f"{links} absolute link(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
