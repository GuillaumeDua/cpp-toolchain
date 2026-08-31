#!/usr/bin/env python3
"""Assert the helper functions duplicated across scripts/install/*.sh have not drifted apart.

Every installer is standalone - `copy the file out and it works`, promised by scripts/install/README.md
and by the `wget` recipe in README.md - so the helpers they share are copied, not sourced.
Copies are the price of that promise; silent divergence between them is not, and is what this catches.

SHARED names one body per function: the scripts that define it must define it identically.
PER_SCRIPT names the functions that appear in several scripts and legitimately differ, each with the reason.
A name carried by more than one script and listed in neither fails as unclassified, so a helper cannot be
copied into a second script without a deliberate choice. A name only one script defines is its own business.

Usage, from the repository root:
    python3 scripts/details/check-install-script-parity.py

Exits non-zero and reports every divergence it found, not only the first.
"""

import hashlib
import pathlib
import re
import sys

sys.dont_write_bytecode = True

HERE = pathlib.Path(__file__).resolve().parent
INSTALL_DIR = HERE.parent / "install"

# Copied verbatim between the scripts that have them. The reporting format and the retry policy
# live here, so a change to either has to land in every copy at once.
SHARED = ("to_boolean", "warning", "log", "run", "run_with_retries")

# Per-script by construction, with why.
PER_SCRIPT = {
    "help": "each script documents its own options",
    "error_diagnosis": "each script reports the repository and the arguments it works with",
    "clean": "only the scripts that download a helper have one to remove",
    "error": "composes this script's error_diagnosis, plus its clean where one exists",
    "select_versions": "gcc and llvm select over different package name shapes",
}

# `name(){` at column 0, through the closing `}` at column 0.
FUNCTION = re.compile(r"^(?P<name>[a-z_][a-z0-9_]*)\(\)\{\n(?P<body>.*?)^\}$", re.M | re.S)


def functions(path):
    """{name: body} for every top-level function in one script."""
    return {m.group("name"): m.group("body") for m in FUNCTION.finditer(path.read_text(encoding="utf-8"))}


def main():
    scripts = sorted(INSTALL_DIR.glob("*.sh"))
    if not scripts:
        raise SystemExit(f"::error::no scripts found under {INSTALL_DIR}")

    defined = {path.name: functions(path) for path in scripts}
    errors = []

    carriers = {}
    for script, bodies in defined.items():
        for name in bodies:
            carriers.setdefault(name, []).append(script)

    for name in sorted(carriers):
        if len(carriers[name]) < 2 or name in SHARED or name in PER_SCRIPT:
            continue
        errors.append(f"{name}(): copied into {', '.join(sorted(carriers[name]))} and classified nowhere "
                      f"- add it to SHARED, or to PER_SCRIPT with a reason")

    checked = 0
    for name in SHARED:
        variants = {}
        for script, bodies in defined.items():
            if name in bodies:
                variants.setdefault(hashlib.sha256(bodies[name].encode()).hexdigest(), []).append(script)
        if not variants:
            errors.append(f"{name}(): listed as shared but defined nowhere")
            continue
        checked += sum(len(group) for group in variants.values())
        if len(variants) > 1:
            groups = " vs ".join("[" + ", ".join(sorted(group)) + "]"
                                 for _, group in sorted(variants.items()))
            errors.append(f"{name}(): {len(variants)} different bodies - {groups}")

    if errors:
        for error in errors:
            print(f"::error::scripts/install: {error}")
        raise SystemExit(1)

    print(f"{len(SHARED)} shared function(s), {checked} copies, all identical "
          f"across {len(scripts)} install script(s)")


if __name__ == "__main__":
    main()
