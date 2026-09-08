#!/usr/bin/env python3
"""Doxygen INPUT_FILTER preparing the repository's markdown for the documentation site.

The markdown under version control is written for GitHub, and two things it cannot carry are added here,
in the stream doxygen reads rather than in the files themselves.

- The page tree, which doxygen builds from `@subpage` and names from a `{#label}` on a page's title.
  GitHub would print both as literal text.
- Absolute GitHub URLs for relative links. The site holds only the pages doxygen renders, so a link to
  anything else - the Dockerfile, an install script, a workflow, a directory - resolves to nothing and 404s.
  Those become `blob` or `tree` URLs according to what the path actually is, and an image needs the bytes
  rather than a page around them, so it points at `raw.githubusercontent.com`.

Links to another markdown file are left alone: doxygen resolves those to the page it generated for them.

Doxygen calls this as `<filter> <file>` and reads the filtered markdown from stdout.
"""

import pathlib
import re
import sys

REPOSITORY_URL = "https://github.com/GuillaumeDua/cpp-toolchain"
RAW_URL = "https://raw.githubusercontent.com/GuillaumeDua/cpp-toolchain"

# The site is published from main, so that is the ref its links point into.
REF = "main"

REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]

MAIN_PAGE = "README.md"

# The site's page tree: every published markdown file, the label naming its page and its output file,
# and the page it hangs under. Reading order is tree order, which is what doxygen shows in the sidebar.
# The main page owns index.html and needs no label of its own.
# A markdown file absent from here is still published, as a page of its own at the top level.
HIERARCHY = (
    ("docs/README.md",              "guides",              MAIN_PAGE),
    ("docs/DEVCONTAINER.md",        "dev-environment",     "docs/README.md"),
    ("docs/CROSS-COMPILATION.md",   "cross-compilation",   "docs/README.md"),
    ("docs/COVERAGE.md",            "coverage",            "docs/README.md"),

    ("scripts/README.md",           "standalone-scripts",  MAIN_PAGE),
    ("scripts/install/README.md",   "install-scripts",     "scripts/README.md"),
    ("scripts/checks/README.md",    "check-scripts",       "scripts/README.md"),

    # `contributing` would collide with README.md's own "Contributing" heading, which doxygen would then
    # renumber to `contributing-1`, breaking the GitHub anchor that section is reached by.
    ("HOW_TO_CONTRIBUTE.md",        "how-to-contribute",   MAIN_PAGE),
    ("docs/IMAGES_VALIDATION.md",   "images-validation",   "HOW_TO_CONTRIBUTE.md"),
    ("docs/RELEASE_PROCESS.md",     "release-process",     "HOW_TO_CONTRIBUTE.md"),
    ("releases/README.md",          "release-records",     "HOW_TO_CONTRIBUTE.md"),
    ("scripts/details/README.md",   "repository-tooling",  "HOW_TO_CONTRIBUTE.md"),
    ("docs/details/README.md",      "documentation-site",  "HOW_TO_CONTRIBUTE.md"),
)

LABEL_OF = {path: label for path, label, _ in HIERARCHY}

CHILDREN_OF: dict[str, list[str]] = {}
for _path, _label, _parent in HIERARCHY:
    CHILDREN_OF.setdefault(_parent, []).append(_label)

# A markdown link or image, split into the leading `!` that tells the two apart, the label, the target
# and the optional #fragment that follows it.
# The label excludes `[` so that a badge, `[![alt](image)](href)`, matches on its inner image rather than
# on the outer link: read the other way round the image would be rewritten to a `blob` URL, which serves
# a page rather than the bytes an `<img>` needs.
LINK = re.compile(r"(?P<image>!?)\[(?P<label>[^\[\]]*)\]\((?P<target>[^)\s#]+)(?P<fragment>#[^)\s]*)?\)")

# A fenced block, whether at the top level or nested in a blockquote.
# The marker is captured because CommonMark closes a block only on the character it opened with,
# so a ``` sample inside a ~~~ block does not end that block.
FENCE = re.compile(r"^\s*(?:>\s*)*(?P<marker>`{3,}|~{3,})")

TITLE = re.compile(r"^#\s+(?P<text>.*?)\s*$")

EXTERNAL_SCHEMES = ("http://", "https://", "mailto:", "ftp://")


def github_url(target: str, source_directory: pathlib.Path, is_image: bool) -> str | None:
    """The GitHub URL for a repository-relative target, or None when the link is left as written."""

    if target.startswith(EXTERNAL_SCHEMES) or target.startswith("/"):
        return None

    path = (source_directory / target).resolve()
    if not path.is_relative_to(REPOSITORY_ROOT) or not path.exists():
        return None

    relative_path = path.relative_to(REPOSITORY_ROOT)
    if path.is_file() and path.suffix == ".md":
        return None

    if is_image:
        return f"{RAW_URL}/{REF}/{relative_path}"

    return f"{REPOSITORY_URL}/{'tree' if path.is_dir() else 'blob'}/{REF}/{relative_path}"


def rewrite(line: str, source_directory: pathlib.Path) -> str:
    def replace(match: re.Match[str]) -> str:
        url = github_url(match["target"], source_directory, bool(match["image"]))
        if url is None:
            return match[0]
        return f"{match['image']}[{match['label']}]({url}{match['fragment'] or ''})"

    return LINK.sub(replace, line)


def main() -> int:
    source = pathlib.Path(sys.argv[1]).resolve()
    source_directory = source.parent
    relative_source = source.relative_to(REPOSITORY_ROOT).as_posix()

    label = LABEL_OF.get(relative_source)
    children = CHILDREN_OF.get(relative_source, ())

    open_marker = None
    title_seen = False

    for line in source.read_text(encoding="utf-8").splitlines(keepends=True):
        fence = FENCE.match(line)
        if fence:
            marker = fence["marker"]
            if open_marker is None:
                open_marker = marker
            elif marker[0] == open_marker[0] and len(marker) >= len(open_marker):
                open_marker = None

        if open_marker:
            sys.stdout.write(line)
            continue

        title = TITLE.match(line)
        if title and not title_seen:
            title_seen = True
            title_line = rewrite(line, source_directory)
            if label:
                title_line = f"# {TITLE.match(title_line)['text']} {{#{label}}}\n"
            if relative_source == MAIN_PAGE:
                # Doxygen gives an ordinary page its outline panel unprompted, and the main page one only
                # where the source asks for it.
                title_line += "\n[TOC]\n"
            sys.stdout.write(title_line)
            continue

        sys.stdout.write(rewrite(line, source_directory))

    # A heading rather than a paragraph: doxygen scopes what follows to the last heading it saw, so a
    # bare paragraph lands inside whatever section the file happens to end on.
    if children:
        sys.stdout.write("\n## In this section\n\n")
        for child in children:
            sys.stdout.write(f"- @subpage {child}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
