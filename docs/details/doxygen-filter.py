#!/usr/bin/env python3
"""Doxygen INPUT_FILTER preparing the repository's markdown for the documentation site.

The markdown under version control is written for GitHub. What the site needs on top of that is settled
here, in the stream doxygen reads rather than in the files themselves.

- A `{#label}` on each page's title, which is the page's name in hierarchy.dox and its file name in the
  output. Without one a page lands at `md_docs_2IMAGES__VALIDATION.html`; GitHub prints the label as
  literal text and shifts the heading's own anchor, so it cannot live in the file.
- `[TOC]` on the main page. Doxygen gives an ordinary page its outline panel unprompted and the main page
  one only where the source asks for it.
- A title cleared of the image README.md sets beside its own. Doxygen carries a title's markup into the
  navigation tree, where the `<img>` tag lands as text in the sidebar label. site.css draws the logo beside
  the main page's title instead, from the copy PROJECT_LOGO leaves in the output.
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

# hierarchy.dox arranges these labels into the tree; the main page owns index.html and needs no label.
# A markdown file absent from here is still published, under the name doxygen derives from its path.
LABEL_OF = {
    "docs/README.md":            "guides",
    "docs/DEVCONTAINER.md":      "dev-environment",
    "docs/CROSS-COMPILATION.md": "cross-compilation",
    "docs/COVERAGE.md":          "coverage",

    "scripts/README.md":         "standalone-scripts",
    "scripts/install/README.md": "install-scripts",
    "scripts/checks/README.md":  "check-scripts",

    # `contributing` would collide with README.md's own "Contributing" heading, which doxygen would then
    # renumber to `contributing-1`, breaking the GitHub anchor that section is reached by.
    "HOW_TO_CONTRIBUTE.md":      "how-to-contribute",
    "docs/IMAGES_VALIDATION.md": "images-validation",
    "docs/RELEASE_PROCESS.md":   "release-process",
    "releases/README.md":        "release-records",
    "scripts/details/README.md": "repository-tooling",
    "docs/details/README.md":    "documentation-site",
}

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

IMAGE = re.compile(r"!\[[^\]]*\]\([^)\s]+\)")

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
            text = rewrite(IMAGE.sub("", title["text"]).strip(), source_directory)
            title_line = f"# {text} {{#{label}}}\n" if label else f"# {text}\n"
            if relative_source == MAIN_PAGE:
                title_line += "\n[TOC]\n"
            sys.stdout.write(title_line)
            continue

        sys.stdout.write(rewrite(line, source_directory))

    return 0


if __name__ == "__main__":
    sys.exit(main())
