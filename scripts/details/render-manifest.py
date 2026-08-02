#!/usr/bin/env python3
"""Render the Dockerfile's pinned versions as a markdown manifest, for a GitHub release description.

Every version these images contain is pinned as an annotated `ARG` in the Dockerfile,
so the manifest is known before anything is built - no image introspection required.

The parsing regexes are read from renovate.json rather than duplicated here. That is deliberate:
if Renovate can bump a pin, this lists it, and if it cannot, neither shows it.
The two cannot drift apart, because there is only one definition.

`UBUNTU_SNAPSHOT` is the documented exception - no datasource can enumerate snapshot timestamps,
so it is matched separately here and bumped by .github/workflows/ubuntu-snapshot.yml.

Usage, from the repository root - `--dockerfile` and `--renovate` default to paths relative to it:
    python3 scripts/details/render-manifest.py --tag v1.2 [--previous-ref v1.1] [--ref <sha>] [--bumps-yaml]

`--ref` reads the Dockerfile and renovate.json from a git ref instead of the worktree,
so the manifest can be rendered for the exact commit an image was built from,
even when the checkout has moved past it.

`--bumps-yaml` emits the moved pins as a YAML `bumps:` mapping instead of the markdown manifest -
the shape recorded in releases/v*.yaml and re-checked by check-release-file.py.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

# depName (or ARG name, for the pins no datasource covers) -> display label, in report order.
# Anything matched but not listed here still appears, under its raw name - so a new pin is never silently dropped from the manifest.
LABELS = [
    ("ubuntu", "Ubuntu"),
    ("UBUNTU_SNAPSHOT", "Ubuntu archive snapshot"),
    ("gcc-mirror/gcc", "GCC"),
    ("llvm/llvm-project", "Clang/LLVM"),
    ("Kitware/CMake", "CMake"),
    ("microsoft/vcpkg", "vcpkg"),
    ("conan", "Conan"),
    ("doxygen/doxygen", "Doxygen"),
    ("build2/build2-toolchain", "build2"),
    ("https://github.com/ohmyzsh/ohmyzsh", "oh-my-zsh"),
    ("romkatv/powerlevel10k", "powerlevel10k"),
]


def js_to_py(pattern):
    """Renovate regexes are JS; Python spells named groups (?P<x>) instead of (?<x>)."""
    return re.sub(r"\(\?<(\w+)>", r"(?P<\1>", pattern)


def dockerfile_managers(renovate_config):
    """The custom managers in renovate.json that read the Dockerfile."""
    for manager in json.loads(renovate_config).get("customManagers", []):
        patterns = manager.get("fileMatch") or manager.get("managerFilePatterns") or []
        if any("Dockerfile" in pattern for pattern in patterns):
            yield manager


def parse(dockerfile, renovate_config):
    """{name: version} for every pin in the Dockerfile, keyed by depName where one exists."""
    found = {}
    for manager in dockerfile_managers(renovate_config):
        for pattern in manager["matchStrings"]:
            for match in re.finditer(js_to_py(pattern), dockerfile):
                groups = match.groupdict()
                name = groups.get("depName") or manager.get("depNameTemplate")
                value = groups.get("currentValue")
                digest = groups.get("currentDigest") or ""
                # A commit-pinned source (oh-my-zsh) has a branch name in currentValue, which says
                # nothing about what was installed - the digest is the version there, shortened for
                # readability. An image digest is the opposite: `24.04` is the useful half, and the
                # sha256 is noise in a release note.
                if re.fullmatch(r"[a-f0-9]{40}", digest):
                    value = digest[:12]
                if not name or not value:
                    continue
                found[name] = value

    # The one pin no manager covers, by design.
    snapshot = re.search(r"^ARG UBUNTU_SNAPSHOT=(\S+)", dockerfile, re.MULTILINE)
    if snapshot:
        found["UBUNTU_SNAPSHOT"] = snapshot.group(1)
    return found


def git_show(ref, path):
    """File contents at a git ref, or None when the ref or file is absent."""
    try:
        return subprocess.run(
            ["git", "show", f"{ref}:{path}"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def delta(current, previous):
    """Markdown cell describing the move from `previous` to `current`."""
    if previous is None:
        return "new"
    if current == previous:
        return "="
    def tup(value):
        parts = []
        for segment in re.split(r"[.\-_]", value):
            if not segment.isdigit():
                break
            parts.append(int(segment))
        return tuple(parts)
    lhs, rhs = tup(current), tup(previous)
    arrow = "⬆" if (lhs and rhs and lhs > rhs) else ("⬇" if (lhs and rhs and lhs < rhs) else "→")
    return f"{arrow} {previous}"


def bumps_yaml(current, previous, diffing):
    """The moved pins as a YAML mapping. JSON quoting keeps this dependency-free:
    every emitted line is a YAML flow mapping, and json.dumps escapes the slashes in depNames."""
    moved = {}
    if diffing:
        for name in sorted(set(current) | set(previous)):
            if current.get(name) != previous.get(name):
                moved[name] = (previous.get(name), current.get(name))
    if not moved:
        return "bumps: {}"
    lines = ["bumps:"]
    for name, (old, new) in moved.items():
        lines.append(f"  {json.dumps(name)}: {{ \"from\": {json.dumps(old)}, \"to\": {json.dumps(new)} }}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="tag being released, e.g. v1.2")
    parser.add_argument("--previous-ref", default="", help="git ref to diff against, e.g. v1.1")
    parser.add_argument("--ref", default="",
                        help="git ref to read the Dockerfile and renovate.json from (default: the worktree)")
    parser.add_argument("--bumps-yaml", action="store_true",
                        help="emit the moved pins as a YAML `bumps:` mapping instead of the markdown manifest")
    parser.add_argument("--dockerfile", default="Dockerfile")
    parser.add_argument("--renovate", default="renovate.json")
    args = parser.parse_args()

    if args.ref:
        renovate_config = git_show(args.ref, args.renovate)
        dockerfile = git_show(args.ref, args.dockerfile)
        if renovate_config is None or dockerfile is None:
            raise SystemExit(f"::error::cannot read {args.dockerfile} / {args.renovate} at ref {args.ref}")
    else:
        renovate_config = pathlib.Path(args.renovate).read_text(encoding="utf-8")
        dockerfile = pathlib.Path(args.dockerfile).read_text(encoding="utf-8")

    current = parse(dockerfile, renovate_config)
    if not current:
        raise SystemExit("::error::no pinned versions found - has the Dockerfile or renovate.json changed shape?")

    previous = {}
    if args.previous_ref:
        old_dockerfile = git_show(args.previous_ref, args.dockerfile)
        if old_dockerfile is None:
            print(f"[render-manifest] no Dockerfile at {args.previous_ref} - rendering without a diff",
                  file=sys.stderr)
        else:
            # The old Dockerfile is parsed with the *current* regexes.
            # Fine in practice: the annotation format is stable, and a pin the old regex could not see reads as "new".
            previous = parse(old_dockerfile, renovate_config)

    diffing = bool(previous)

    if args.bumps_yaml:
        print(bumps_yaml(current, previous, diffing))
        return

    ordered = [name for name, _ in LABELS if name in current]
    ordered += sorted(name for name in current if name not in dict(LABELS))
    labels = dict(LABELS)

    out = ["<!-- manifest:begin -->", f"## What's inside {args.tag}", ""]
    out.append("| Component | Version |" + (f" Since {args.previous_ref} |" if diffing else ""))
    out.append("| --- | --- |" + (" --- |" if diffing else ""))
    for name in ordered:
        row = f"| {labels.get(name, name)} | `{current[name]}` |"
        if diffing:
            row += f" {delta(current[name], previous.get(name))} |"
        out.append(row)

    out += [
        "",
        "Every version listed above is pinned in the [Dockerfile](Dockerfile) and kept current by Renovate,  ",
        "so this table is the authoritative manifest of the image's contents, not a point-in-time snapshot.",
        "",
        "<!-- manifest:end -->"
    ]
    print("\n".join(out))


if __name__ == "__main__":
    main()
