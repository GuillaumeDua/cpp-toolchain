#!/usr/bin/env python3
"""Doxygen INPUT_FILTER pointing the repository's relative links at GitHub.

The markdown under version control is written for GitHub, where a link reaches any file in the tree.
The published site holds only the pages doxygen renders, so a relative link to anything else -
the Dockerfile, an install script, a workflow, a directory - resolves to nothing and 404s.
Those become absolute GitHub URLs, `blob` or `tree` according to what the path actually is.

Links to another markdown file are left alone: doxygen resolves those to the page it generated for them.

Doxygen calls this as `<filter> <file>` and reads the filtered markdown from stdout.
"""

import pathlib
import re
import sys

REPOSITORY_URL = "https://github.com/GuillaumeDua/cpp-toolchain"

# The site is published from main, so that is the ref its links point into.
REF = "main"

REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]

# The target of a markdown link or image, split from the optional #fragment that follows it.
LINK_TARGET = re.compile(r"(?<=\]\()(?P<target>[^)\s#]+)(?P<fragment>#[^)\s]*)?(?=\))")

# A fenced block, whether at the top level or nested in a blockquote.
# The marker is captured because CommonMark closes a block only on the character it opened with,
# so a ``` sample inside a ~~~ block does not end that block.
FENCE = re.compile(r"^\s*(?:>\s*)*(?P<marker>`{3,}|~{3,})")

EXTERNAL_SCHEMES = ("http://", "https://", "mailto:", "ftp://")


def github_url(target: str, source_directory: pathlib.Path) -> str | None:
    """The GitHub URL for a repository-relative link target, or None when the link is left as written."""

    if target.startswith(EXTERNAL_SCHEMES) or target.startswith("/"):
        return None

    path = (source_directory / target).resolve()
    if not path.is_relative_to(REPOSITORY_ROOT) or not path.exists():
        return None

    relative_path = path.relative_to(REPOSITORY_ROOT)
    if path.is_file() and path.suffix == ".md":
        return None

    return f"{REPOSITORY_URL}/{'tree' if path.is_dir() else 'blob'}/{REF}/{relative_path}"


def rewrite(line: str, source_directory: pathlib.Path) -> str:
    def replace(match: re.Match[str]) -> str:
        url = github_url(match["target"], source_directory)
        if url is None:
            return match[0]
        return url + (match["fragment"] or "")

    return LINK_TARGET.sub(replace, line)


def main() -> int:
    source = pathlib.Path(sys.argv[1]).resolve()
    source_directory = source.parent

    open_marker = None
    for line in source.read_text(encoding="utf-8").splitlines(keepends=True):
        fence = FENCE.match(line)
        if fence:
            marker = fence["marker"]
            if open_marker is None:
                open_marker = marker
            elif marker[0] == open_marker[0] and len(marker) >= len(open_marker):
                open_marker = None
        sys.stdout.write(line if open_marker else rewrite(line, source_directory))

    return 0


if __name__ == "__main__":
    sys.exit(main())
