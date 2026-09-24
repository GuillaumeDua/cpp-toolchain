#!/usr/bin/env python3
"""Inline scripts/details/shared.sh into a script that sources it, producing the standalone copy.

The scripts under scripts/install/ and scripts/checks/ source their shared helpers, so a checkout
holds one body per helper. What is published for each release is this script's output: the same
script with the `source` line replaced by the helpers it needs, which is what makes
`wget <one url> && bash <one file>` work on a machine that has never seen this repository.

Which helpers get inlined is resolved from the script's own calls, closed over the library's internal
ones - run_with_retries calls run and warning. The scan errs toward including one too many: a false
positive leaves an unused function in the output, a false negative ships a script that dies on its
first call. The standalone smoke test in .github/workflows/docker-build.yml is what catches a miss.

A script that sources nothing composes to itself, which is how doxygen.sh passes through.

Usage:
    python3 scripts/details/compose-standalone.py scripts/install/gcc.sh > gcc.sh
    python3 scripts/details/compose-standalone.py --all <directory>

Writes to stdout, or with --all one file per script into the directory given.
"""

import argparse
import pathlib
import re
import sys

sys.dont_write_bytecode = True

HERE = pathlib.Path(__file__).resolve().parent
LIBRARY = HERE / "shared.sh"

# The `source` line to replace, plus the comment block above it that explains why it is there.
SOURCE_LINE = re.compile(
    r"(?:^#[^\n]*\n)*^source \"\$\(dirname -- \"\$\(readlink -f -- \"\$\{BASH_SOURCE\[0\]\}\"\)\"\)/"
    r"[^\"]*shared\.sh\"\n",
    re.M)

FUNCTION = re.compile(r"^(?P<name>[a-z_][a-z0-9_]*)\(\)[ \t]*\{[ \t]*\n.*?^\}$", re.M | re.S)
ONE_LINER = re.compile(r"^(?P<name>[a-z_][a-z0-9_]*)\(\)[ \t]*\{[^\n]*\}[ \t]*$", re.M)

# Everything above the first declaration: the defaults, the dpkg probe and the failure counter.
PRELUDE_END = re.compile(r"^[a-z_][a-z0-9_]*\(\)", re.M)

# What a prelude line establishes: `: "${name:=...}"` or a plain `name=`.
ESTABLISHES = re.compile(r"^(?::\s*\"\$\{(?P<defaulted>[a-z_][a-z0-9_]*):=|(?P<assigned>[a-z_][a-z0-9_]*)=)")


def without_comments(text):
    """`text` with comment lines and trailing comments dropped, so a call scan cannot match prose."""
    text = re.sub(r"^\s*#.*$", "", text, flags=re.M)
    return re.sub(r"\s#[^\n]*$", "", text, flags=re.M)


def declarations(text):
    """[(name, source text)] for every function, in the order they appear.

    The comment lines directly above a function come with it: they carry the rationale a reader of
    the published standalone script has no other way to reach.
    """
    lines = text.splitlines(keepends=True)
    starts = [0]
    for line in lines[:-1]:
        starts.append(starts[-1] + len(line))

    found = []
    for pattern in (FUNCTION, ONE_LINER):
        for match in pattern.finditer(text):
            first = text[:match.start()].count("\n")
            while first > 0 and lines[first - 1].lstrip().startswith("#"):
                first -= 1
            found.append((match.start(), match.group("name"), text[starts[first]:match.end()]))
    return [(name, body) for _, name, body in sorted(found)]


def calls(text, names):
    """The subset of `names` that `text` calls, read at command positions only.

    A name reached any other way - a `case` branch spelled `run )`, a variable, a word in a string -
    matches too. That is the intended direction: over-including costs an unused function.
    """
    stripped = without_comments(text)
    return {name for name in names
            if re.search(rf"(?:^|[;&|(`]|\|\||&&|\$\()\s*{name}(?:\s|$|\))", stripped, re.M)}


def needed_prelude(prelude, wanted, bodies, script_text):
    """The prelude blocks an inlined helper reads and the script does not already establish itself.

    Every script sets its own `this_script_name`, and the install ones their own `arg_silent`, so
    most of the prelude composes away: what is left is the dpkg probe behind package_of and the
    counter behind fail.
    """
    blocks, current = [], []
    for line in prelude.splitlines():
        if line.startswith("#"):
            continue
        if not line.strip():
            if current:
                blocks.append(current)
                current = []
            continue
        # A defaulting line stands alone; anything else groups with the lines beside it.
        if ESTABLISHES.match(line) and line.startswith(":") and current:
            blocks.append(current)
            current = []
        current.append(line)
    if current:
        blocks.append(current)

    kept = []
    for block in blocks:
        names = {match.group("defaulted") or match.group("assigned")
                 for match in (ESTABLISHES.match(line) for line in block) if match}
        read_by_a_helper = any(re.search(rf"\b{name}\b", bodies[helper])
                               for name in names for helper in wanted)
        set_by_the_script = any(re.search(rf"^\s*(?::\s*\"\$\{{)?{name}[=:]", script_text, re.M)
                                for name in names)
        if read_by_a_helper and not set_by_the_script:
            kept.append("\n".join(block))
    return "\n\n".join(kept)


def compose(script_text):
    """`script_text` with its `source` line replaced by the library helpers it needs."""
    if not SOURCE_LINE.search(script_text):
        return script_text

    library = LIBRARY.read_text(encoding="utf-8")
    bodies = dict(declarations(library))

    # A script that sources the library and also declares one of its helpers composes to a file
    # holding both, where the later definition silently wins. Refuse instead: whichever copy is
    # meant to be authoritative, carrying two is not it.
    shadowed = sorted(set(dict(declarations(script_text))) & set(bodies))
    if shadowed:
        raise SystemExit(f"::error::{', '.join(f'{name}()' for name in shadowed)} "
                         f"also declared in {LIBRARY.name} - source it or rename it, not both")

    # Close over the library's own calls: asking for run_with_retries has to bring run and warning.
    wanted = calls(script_text, bodies)
    while True:
        grown = wanted | {name for entry in wanted for name in calls(bodies[entry], bodies)}
        if grown == wanted:
            break
        wanted = grown

    inlined = ["# Inlined from scripts/details/shared.sh by scripts/details/compose-standalone.py."]
    prelude = needed_prelude(library[:PRELUDE_END.search(library).start()], wanted, bodies,
                             script_text)
    if prelude:
        inlined += [prelude, ""]
    for name, body in declarations(library):
        if name in wanted:
            inlined += [body, ""]

    # A function, not a string: the helper bodies carry backslash sequences - `\1` in soname_of's
    # sed expression - that re.sub would read as group references in a replacement template.
    replacement = "\n".join(inlined).rstrip() + "\n"
    return SOURCE_LINE.sub(lambda _: replacement, script_text, count=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("script", help="the script to compose, or the source directory with --all")
    parser.add_argument("--all", metavar="OUT_DIR",
                        help="compose every .sh under `script` into OUT_DIR, keeping the file names")
    arguments = parser.parse_args()

    if not LIBRARY.is_file():
        raise SystemExit(f"::error::{LIBRARY} not found")

    if not arguments.all:
        print(compose(pathlib.Path(arguments.script).read_text(encoding="utf-8")), end="")
        return

    out_dir = pathlib.Path(arguments.all)
    out_dir.mkdir(parents=True, exist_ok=True)
    for path in sorted(pathlib.Path(arguments.script).glob("*.sh")):
        composed = out_dir / path.name
        composed.write_text(compose(path.read_text(encoding="utf-8")), encoding="utf-8")
        composed.chmod(0o755)
        print(f"{path} -> {composed}")


if __name__ == "__main__":
    main()
