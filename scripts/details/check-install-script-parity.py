#!/usr/bin/env python3
"""Assert the helper functions copied out of scripts/details/shared.sh have not drifted from it.

Every script under scripts/install/ and scripts/checks/ is standalone - `copy the file out and it works`,
promised by scripts/install/README.md, scripts/checks/README.md and by the `wget` recipes in both.
The Dockerfile copies each install script on its own, so a sibling one of them sourced would not be in
the image: the copies are what the promise costs.

scripts/details/shared.sh holds one body per shared helper, and is what those copies are generated from.
Each copy is compared against it, so a divergence names the file that moved. `--fix` rewrites the
copies instead of reporting them.

PER_SCRIPT names the functions that appear in several scripts and legitimately differ, each with the
reason. A name carried by more than one script, absent from the library and from PER_SCRIPT, fails as
unclassified, so a helper cannot be copied into a second script without a deliberate choice. A name only
one script defines is its own business.

Out of scope, deliberately:
    Only install/ and checks/ are searched for copies. shared.sh is read because it is the library,
    but the rest of scripts/details/ is not: build-stages.sh keeps a die() of its own - a `::error::`
    annotation and exit 2, addressed to a workflow rather than a terminal - and cxx-toolchain-versions.sh
    inlines the epoch and revision stripping that version_of_package owns, which is not a function and
    no pattern here would reach.

Usage, from the repository root:
    python3 scripts/details/check-install-script-parity.py [--fix]

Exits non-zero and reports every divergence it found, not only the first.
"""

import argparse
import pathlib
import re
import sys

sys.dont_write_bytecode = True

HERE = pathlib.Path(__file__).resolve().parent
SCRIPTS_DIR = HERE.parent
LIBRARY = HERE / "shared.sh"

# The directories whose scripts carry the standalone promise. checks/ is walked recursively: its
# details/ gate scripts compose the public ones and share their shape.
SCRIPT_DIRS = ("install", "checks")

# Per-script by construction, with why.
PER_SCRIPT = {
    "help": "each script documents its own options",
    "error_diagnosis": "each script reports the repository and the arguments it works with",
    "clean": "only the scripts that download a helper have one to remove",
    "error": "composes this script's error_diagnosis, plus its clean where one exists",
    "select_versions": "gcc and llvm select over different package name shapes",
    "set_format": "each script offers the formats its own view can answer",
    "discover_library_files": "each script globs for its own implementation's runtime",
    "library_rows": "each script reads the fields its implementation has - libc++ alone needs headers",
    "render": "each script prints its own field set",
}

# `name(){` at column 0, through the closing `}` at column 0.
FUNCTION = re.compile(r"^(?P<name>[a-z_][a-z0-9_]*)\(\)\{\n(?P<body>.*?)^\}$", re.M | re.S)

# `name() { ...; }` on one line. Anchoring on the parameter list is what keeps a `local` declaration
# out: none of them carries `()`. The space before the brace has to be tolerated, not required -
# every die, fail and pass in the tree is spelled `name() {`, and a few use two spaces.
ONE_LINER = re.compile(r"^(?P<name>[a-z_][a-z0-9_]*)\(\)[ \t]*\{(?P<body>[^\n]*[^\s])[ \t]*\}[ \t]*$",
                       re.M)

# A declaration opening at column 0, whatever follows it. Counted against what the two patterns
# above actually read: a helper spelled in a third way - a trailing comment on the opening line,
# a brace on the next line - would otherwise drop out of the comparison silently, still copied
# but no longer guarded.
DECLARATION = re.compile(r"^(?P<name>[a-z_][a-z0-9_]*)\(\)", re.M)


def scripts_under(directory):
    """Every shell script under one of SCRIPT_DIRS, recursively."""
    return sorted((SCRIPTS_DIR / directory).rglob("*.sh"))


def functions(text):
    """{name: (form, body)} for every top-level function in one script."""
    found = {}
    for form, pattern in (("block", FUNCTION), ("one-liner", ONE_LINER)):
        for match in pattern.finditer(text):
            body = match.group("body")
            found[match.group("name")] = (form, body.strip() if form == "one-liner" else body)
    return found


def render(name, form, body):
    """One function, spelled the way the scripts spell it."""
    return f"{name}() {{ {body} }}" if form == "one-liner" else f"{name}(){{\n{body}}}"


def rewritten(text, library):
    """`text` with every declaration of a library function replaced by the library's.

    Both patterns run, so a copy that spells a helper in the other form is brought back to the
    library's spelling rather than left alone.
    """
    def swap(match):
        name = match.group("name")
        return render(name, *library[name]) if name in library else match.group(0)

    return ONE_LINER.sub(swap, FUNCTION.sub(swap, text))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fix", action="store_true",
                        help="rewrite every copy from scripts/details/shared.sh instead of reporting it")
    arguments = parser.parse_args()

    if not LIBRARY.is_file():
        raise SystemExit(f"::error::{LIBRARY.relative_to(SCRIPTS_DIR.parent)} not found")
    library = functions(LIBRARY.read_text(encoding="utf-8"))
    if not library:
        raise SystemExit(f"::error::{LIBRARY.name} declares no function")

    scripts = [path for directory in SCRIPT_DIRS for path in scripts_under(directory)]
    if not scripts:
        raise SystemExit(f"::error::no scripts found under {', '.join(SCRIPT_DIRS)}")

    # Keyed by the path below scripts/, so two directories holding the same file name stay distinct.
    defined = {path: functions(path.read_text(encoding="utf-8")) for path in scripts}
    errors = []

    carriers = {}
    for path, bodies in defined.items():
        for name in bodies:
            carriers.setdefault(name, []).append(str(path.relative_to(SCRIPTS_DIR)))

    for name in sorted(carriers):
        if len(carriers[name]) < 2 or name in library or name in PER_SCRIPT:
            continue
        errors.append(f"{name}(): copied into {', '.join(sorted(carriers[name]))} and classified nowhere"
                      f" - add it to {LIBRARY.name}, or to PER_SCRIPT with a reason")

    for name in sorted(library):
        if name not in carriers:
            errors.append(f"{name}(): declared in {LIBRARY.name} and copied into no script"
                          " - remove it, or classify it as sourced-only")

    for path, bodies in sorted(defined.items()):
        unread = {match.group("name") for match in DECLARATION.finditer(path.read_text(encoding="utf-8"))}
        unread -= set(bodies)
        for name in sorted(unread):
            errors.append(f"{name}(): {path.relative_to(SCRIPTS_DIR)} declares it in a form this script"
                          " cannot read - spell it `name(){` on its own line, or `name() { ...; }`")

    copies = 0
    for path, bodies in sorted(defined.items()):
        where = path.relative_to(SCRIPTS_DIR)
        drifted = []
        for name, declaration in sorted(bodies.items()):
            if name not in library:
                continue
            copies += 1
            if declaration != library[name]:
                drifted.append(name)
        if not drifted:
            continue
        if not arguments.fix:
            errors += [f"{name}(): {where} differs from {LIBRARY.name}" for name in drifted]
            continue
        path.write_text(rewritten(path.read_text(encoding="utf-8"), library), encoding="utf-8")
        print(f"rewrote {', '.join(f'{name}()' for name in drifted)} in {where}")

    if errors:
        for error in errors:
            print(f"::error::scripts: {error}")
        raise SystemExit(1)

    print(f"{len(library)} shared function(s) in {LIBRARY.name}, {copies} copies, all identical "
          f"across {len(scripts)} standalone script(s)")


if __name__ == "__main__":
    main()
