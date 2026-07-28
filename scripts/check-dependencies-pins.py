#!/usr/bin/env python3
"""Assert every version the images install is pinned, watched by Renovate, and declared exactly once.

Three invariants, all cheap, all failing long before a 40-minute build:

  1. nothing floats     - a `latest` / `master` value makes two builds of one commit differ
  2. nothing is unwatched - a pin nobody updates silently rots
  3. nothing is shadowed  - a stage re-declaring `ARG FOO=<value>` overrides the global pin,
                            which is the exact bug hoisting the ARGs was meant to remove

"Watched" is not decided by guessing which ARG names look like versions. The renovate.json manager
regexes are run over the Dockerfile and the matched character spans recorded; an ARG line inside a
span is one Renovate can actually see. So the check tests the real manager set rather than a naming
convention, and an oddly-named pin (`ARG NODE_TAG=22`) fails instead of slipping through.

`UBUNTU_SNAPSHOT` is the one documented exception - no datasource can enumerate snapshot timestamps,
so it is bumped by .github/workflows/ubuntu-snapshot.yml instead.

Usage:
    check-dependencies-pins.py [--dockerfile Dockerfile] [--renovate renovate.json]

Exits non-zero and reports every violation it found, rather than only the first.
"""

import argparse
import importlib.util
import os
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent

# Importing render-manifest.py below would drop a scripts/__pycache__/ next to the sources,
# on every local run and every CI run. Nothing reimports these often enough for the cache to pay off.
sys.dont_write_bytecode = True

# ARG name -> why it carries no Renovate annotation.
EXEMPT = {
    "UBUNTU_SNAPSHOT": "bumped by .github/workflows/ubuntu-snapshot.yml - no datasource can enumerate snapshot timestamps",
}

# Values that mean "whatever is newest at build time".
FLOATING = re.compile(r"latest|master")

ARG_DECL = re.compile(r"^ARG ([A-Za-z_][A-Za-z0-9_]*)=(\S+)")


def load_render_manifest():
    """render-manifest.py, imported by path - the hyphen makes it not a normal module name.

    Sharing js_to_py/dockerfile_managers is the point: both tools have to read renovate.json
    the same way, or the manifest and this guard disagree about what Renovate covers.
    """
    spec = importlib.util.spec_from_file_location("render_manifest", HERE / "render-manifest.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def split_at_first_stage(dockerfile):
    """(global_lines, stage_lines) as [(lineno, text)], split at the first `FROM`.

    Only the global block declares pins; everything after it should re-declare them bare.
    """
    lines = dockerfile.split("\n")
    first_from = next((i for i, line in enumerate(lines) if line.startswith("FROM ")), len(lines))
    numbered = list(enumerate(lines, start=1))
    return numbered[:first_from], numbered[first_from:]


def watched_spans(dockerfile, renovate_config, render_manifest):
    """Character ranges of the Dockerfile that a renovate.json custom manager matches."""
    spans = []
    for manager in render_manifest.dockerfile_managers(renovate_config):
        for pattern in manager["matchStrings"]:
            for match in re.finditer(render_manifest.js_to_py(pattern), dockerfile):
                spans.append((match.start(), match.end()))
    return spans


def line_offsets(dockerfile):
    """{lineno: (start, end)} character offsets, so a line can be tested against a span."""
    offsets = {}
    cursor = 0
    for lineno, line in enumerate(dockerfile.split("\n"), start=1):
        offsets[lineno] = (cursor, cursor + len(line))
        cursor += len(line) + 1
    return offsets


def check(dockerfile, renovate_config, render_manifest):
    """[(lineno, message)] for every violation - empty when the Dockerfile is sound."""
    problems = []
    global_lines, stage_lines = split_at_first_stage(dockerfile)
    spans = watched_spans(dockerfile, renovate_config, render_manifest)
    offsets = line_offsets(dockerfile)

    declared = {}
    for lineno, line in global_lines:
        match = ARG_DECL.match(line)
        if not match:
            continue
        name, value = match.group(1), match.group(2)
        declared[name] = lineno

        if FLOATING.search(value):
            problems.append((lineno, f"{name}={value} floats - pin it to an exact version"))

        if name in EXEMPT:
            continue

        start, end = offsets[lineno]
        if not any(span_start < end and start < span_end for span_start, span_end in spans):
            problems.append((
                lineno,
                f"{name}={value} is pinned but no renovate.json manager matches it - "
                f"add a `# renovate:` annotation directly above, or exempt it in {pathlib.Path(__file__).name}",
            ))

    for lineno, line in stage_lines:
        match = ARG_DECL.match(line)
        if match and match.group(1) in declared:
            name = match.group(1)
            problems.append((
                lineno,
                f"{name} is re-declared with a value here, shadowing the global pin on line "
                f"{declared[name]} - re-declare it bare (`ARG {name}`) to inherit it",
            ))

    return problems, declared


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dockerfile", default="Dockerfile")
    parser.add_argument("--renovate", default="renovate.json")
    args = parser.parse_args()

    dockerfile = pathlib.Path(args.dockerfile).read_text(encoding="utf-8")
    renovate_config = pathlib.Path(args.renovate).read_text(encoding="utf-8")

    problems, declared = check(dockerfile, renovate_config, load_render_manifest())

    # Annotations render inline on the diff under Actions; plain text is more readable in a terminal.
    on_actions = bool(os.environ.get("GITHUB_ACTIONS"))
    for lineno, message in problems:
        if on_actions:
            print(f"::error file={args.dockerfile},line={lineno}::{message}")
        else:
            print(f"{args.dockerfile}:{lineno}: error: {message}", file=sys.stderr)

    if problems:
        return 1

    watched = len(declared) - len(EXEMPT & declared.keys())
    print(f"{watched} pin(s) tracked by Renovate, {len(EXEMPT & declared.keys())} exempt, "
          f"none floating, none shadowed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
