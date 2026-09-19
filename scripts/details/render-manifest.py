#!/usr/bin/env python3
"""Render the Dockerfile's pinned versions as a markdown manifest, for a GitHub release description.

Every version these images request is pinned as an annotated `ARG` in the Dockerfile,
so the manifest is known before anything is built - no image introspection required.
A pin is not always an exact version - GCC and Clang pin a major. See README.md#whats-inside-a-given-tag.

The parsing regexes are read from renovate.json rather than duplicated here, so there is one
definition and the two cannot drift apart: if Renovate can bump a pin, this lists it, and if it
cannot, neither shows it.

`UBUNTU_SNAPSHOT` is the documented exception - no datasource can enumerate snapshot timestamps,
so it is matched separately here and bumped by .github/workflows/ubuntu-snapshot.yml.

Usage, from the repository root - `--dockerfile` and `--renovate` default to paths relative to it:
    python3 scripts/details/render-manifest.py --tag v1.2 [--previous-ref v1.1] [--ref <sha>] [--bumps-yaml]
    python3 scripts/details/render-manifest.py --replace-region manifest --with note.md < body.md

`--previous-ref` defaults to the newest release before `--tag`, which is the base every caller
wants, so no caller computes one. Pass `--previous-ref ''` for a manifest with no changes section.
A named ref that cannot be read, or that parses to no pins, is never silently rendered as "nothing
moved": `--bumps-yaml` fails, because an unverifiable `{}` in an immutable record reads as a
verified one, and the markdown says it is not comparable.

`--replace-region` edits a release body in place around the `<!-- name:begin -->` markers this
script emits, and refuses an unbalanced pair. Every caller that upserts a release body goes
through it, so hand-written prose outside the region survives a re-run.

Which tags count as releases, how they order, and where the images are published are all
check-release-file.py's, read from here rather than restated: the tag docker-publish.yml
publishes, the base this manifest diffs against, and the reference it tells readers to pull
cannot disagree.

`--ref` reads the Dockerfile and renovate.json from a git ref instead of the worktree,
so the manifest can be rendered for the exact commit an image was built from,
even when the checkout has moved past it.

`--bumps-yaml` emits the moved pins as a YAML `bumps:` mapping instead of the markdown manifest -
the shape recorded in releases/v*.yaml and re-checked by check-release-file.py.
"""

import argparse
import importlib.util
import json
import pathlib
import re
import subprocess
import sys

# Importing check-release-file.py below would drop a scripts/details/__pycache__/ next to the
# sources, on every local run and every CI run.
sys.dont_write_bytecode = True

HERE = pathlib.Path(__file__).resolve().parent

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

def load_check_release_file():
    """check-release-file.py, imported by path - the hyphen makes it not a normal module name.

    It owns the version grammar and the registry references:
        the tag the workflows publish, the base this note diffs against, and the image it tells
        readers to pull are then one answer rather than three spellings of it.
    """
    spec = importlib.util.spec_from_file_location("check_release_file", HERE / "check-release-file.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


schema = load_check_release_file()
newest_release_before = schema.newest_release_before

GHCR_REFERENCE = schema.REGISTRIES["ghcr"]
DOCKERHUB_REFERENCE = schema.REGISTRIES["dockerhub"]

# Browsable pages rather than pull references: the repository and the GHCR package live on
# github.com, Docker Hub's page under /r/. Derived, so the owner and image name are spelled once.
# github.com paths are case-insensitive, so the lowercase a registry reference carries resolves.
REPOSITORY_PAGE = f"https://github.com/{GHCR_REFERENCE.split('/', 1)[1]}"
GHCR_PAGE = f"{REPOSITORY_PAGE}/pkgs/container/{GHCR_REFERENCE.rsplit('/', 1)[1]}"
DOCKERHUB_PAGE = f"https://hub.docker.com/r/{DOCKERHUB_REFERENCE.split('/', 1)[1]}"


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
    """({name: version}, {name: versioning}) for every pin in the Dockerfile, keyed by depName where one exists."""
    found = {}
    schemes = {}
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
                if groups.get("versioning"):
                    schemes[name] = groups["versioning"]

    # The one pin no manager covers, by design.
    snapshot = re.search(r"^ARG UBUNTU_SNAPSHOT=(\S+)", dockerfile, re.MULTILINE)
    if snapshot:
        found["UBUNTU_SNAPSHOT"] = snapshot.group(1)
    return found, schemes


def render_version(value, versioning):
    """`value` as a dotted version when its Renovate scheme can name the parts, verbatim otherwise.

    Doxygen pins the git tag `Release_1_18_0` while the image reports `1.18.0`, and a manifest of
    what is installed wants the latter. The scheme that governs the bump already says where the
    numbers are, so reading it keeps that mapping in one place.
    """
    if not versioning or not versioning.startswith("regex:"):
        return value
    # `search`, not `fullmatch`: the scheme declares its own anchors.
    match = re.search(js_to_py(versioning[len("regex:"):]), value)
    if not match:
        return value
    groups = match.groupdict()
    # The numeric parts Renovate's regex versioning names, in version order. `compatibility` is not
    # one of them, and `prerelease` is a suffix rather than a part.
    parts = [groups[part] for part in ("major", "minor", "patch", "build", "revision") if groups.get(part)]
    if not parts:
        return value
    prerelease = groups.get("prerelease")
    return ".".join(parts) + (f"-{prerelease}" if prerelease else "")


def git_show(ref, path):
    """File contents at a git ref, or None when the ref or file is absent."""
    try:
        return subprocess.run(
            ["git", "show", f"{ref}:{path}"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def replace_region(body, name, replacement, when_absent):
    """`body` with the `<!-- name:begin -->` / `<!-- name:end -->` region replaced by `replacement`.

    An unbalanced pair is a corrupt body, not an instruction to delete the rest of it: a
    `sed '/begin/,/end/d'` runs to end-of-file when the closing marker is missing, taking any
    hand-written release prose with it.
    """
    begin, end = f"<!-- {name}:begin -->", f"<!-- {name}:end -->"
    lines = body.splitlines()
    starts = [index for index, line in enumerate(lines) if line.strip() == begin]
    ends = [index for index, line in enumerate(lines) if line.strip() == end]

    if len(starts) > 1 or len(ends) > 1 or len(starts) != len(ends):
        raise SystemExit(f"::error::{name}: found {len(starts)} '{begin}' and {len(ends)} '{end}'"
                         " - expected exactly one of each, or neither")
    if not starts:
        block = replacement.splitlines()
        ordered = block + [""] + lines if when_absent == "prepend" else lines + [""] + block
        return "\n".join(ordered)
    if ends[0] < starts[0]:
        raise SystemExit(f"::error::{name}: '{end}' precedes '{begin}'")
    return "\n".join(lines[:starts[0]] + replacement.splitlines() + lines[ends[0] + 1:])


def moved_pins(current, previous):
    """{name: (old, new)} for every pin whose value differs, `None` on the side it is absent from.

    Over the union of both sides, so a pin added to or dropped from the Dockerfile shows up
    as well as one re-pinned. Sorted by name, not display order.
    """
    return {
        name: (previous.get(name), current.get(name))
        for name in sorted(set(current) | set(previous))
        if current.get(name) != previous.get(name)
    }


def change_lines(moved, labels, order, schemes):
    """One markdown bullet per moved pin, in the manifest's display order, dropped pins last.

    Both values sit in the bullet, so the move reads left to right and needs no direction glyph.
    """
    names = [name for name in order if name in moved]
    names += [name for name in moved if name not in order]
    lines = []
    for name in names:
        old, new = moved[name]
        label = labels.get(name, name)
        versioning = schemes.get(name)
        if old is None:
            lines.append(f"- {label}: added, `{render_version(new, versioning)}`")
        elif new is None:
            lines.append(f"- {label}: removed, was `{render_version(old, versioning)}`")
        else:
            lines.append(f"- {label}: `{render_version(old, versioning)}` → `{render_version(new, versioning)}`")
    return lines


def bumps_yaml(current, previous, diffing):
    """The moved pins as a YAML mapping. JSON quoting keeps this dependency-free:
    every emitted line is a YAML flow mapping, and json.dumps escapes the slashes in depNames."""
    moved = moved_pins(current, previous) if diffing else {}
    if not moved:
        return "bumps: {}"
    lines = ["bumps:"]
    for name, (old, new) in moved.items():
        lines.append(f"  {json.dumps(name)}: {{ \"from\": {json.dumps(old)}, \"to\": {json.dumps(new)} }}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="tag being released, e.g. v1.2")
    parser.add_argument("--previous-ref", default=None,
                        help="git ref to diff against (default: the newest release before --tag; '' for no diff)")
    parser.add_argument("--ref", default="",
                        help="git ref to read the Dockerfile and renovate.json from (default: the worktree)")
    parser.add_argument("--bumps-yaml", action="store_true",
                        help="emit the moved pins as a YAML `bumps:` mapping instead of the markdown manifest")
    parser.add_argument("--replace-region", metavar="NAME",
                        help="replace the <!-- NAME:begin --> region of a release body read on stdin (no --tag needed)")
    parser.add_argument("--with", dest="replacement", metavar="FILE",
                        help="the replacement block, for --replace-region")
    parser.add_argument("--when-absent", choices=["append", "prepend"], default="append",
                        help="where to put the block when the region is not there yet (default: append)")
    parser.add_argument("--dockerfile", default="Dockerfile")
    parser.add_argument("--renovate", default="renovate.json")
    args = parser.parse_args()

    if args.replace_region:
        if not args.replacement:
            parser.error("--replace-region needs --with FILE")
        replacement = pathlib.Path(args.replacement).read_text(encoding="utf-8")
        print(replace_region(sys.stdin.read(), args.replace_region, replacement, args.when_absent))
        return

    if not args.tag:
        parser.error("--tag is required")

    if args.ref:
        renovate_config = git_show(args.ref, args.renovate)
        dockerfile = git_show(args.ref, args.dockerfile)
        if renovate_config is None or dockerfile is None:
            raise SystemExit(f"::error::cannot read {args.dockerfile} / {args.renovate} at ref {args.ref}")
    else:
        renovate_config = pathlib.Path(args.renovate).read_text(encoding="utf-8")
        dockerfile = pathlib.Path(args.dockerfile).read_text(encoding="utf-8")

    current, schemes = parse(dockerfile, renovate_config)
    if not current:
        raise SystemExit("::error::no pinned versions found - has the Dockerfile or renovate.json changed shape?")

    previous_ref = newest_release_before(args.tag) if args.previous_ref is None else args.previous_ref

    previous = {}
    undiffable = ""
    if previous_ref:
        old_dockerfile = git_show(previous_ref, args.dockerfile)
        if old_dockerfile is None:
            undiffable = f"{args.dockerfile} does not exist at {previous_ref}"
        else:
            # The old Dockerfile is parsed with the *current* regexes.
            # Fine in practice: the annotation format is stable, and a pin the old regex could not see reads as added.
            previous, _ = parse(old_dockerfile, renovate_config)
            if not previous:
                undiffable = (f"no pinned versions found in {args.dockerfile} at {previous_ref}"
                              " - the renovate.json manager regexes no longer match it")

    # The two outputs answer differently because their readers differ.
    # `bumps:` lands in an immutable record, where an unverifiable `{}` is indistinguishable from a
    # verified "nothing moved", so it fails instead. The markdown says so and renders the rest.
    if undiffable:
        if args.bumps_yaml:
            raise SystemExit(f"::error::cannot diff against {previous_ref}: {undiffable}")
        print(f"::warning::cannot diff against {previous_ref}: {undiffable}", file=sys.stderr)

    diffing = bool(previous_ref)

    if args.bumps_yaml:
        print(bumps_yaml(current, previous, diffing))
        return

    ordered = [name for name, _ in LABELS if name in current]
    ordered += sorted(name for name in current if name not in dict(LABELS))
    labels = dict(LABELS)

    # GHCR URLs cannot filter versions by tag name (its per-tag pages are keyed by a numeric
    # version id only the Packages API knows), so the closest deep link is the tagged-only view.
    out = [
        "<!-- manifest:begin -->",
        f"## What's inside {args.tag}",
        "",
        f"Published to [GHCR]({GHCR_PAGE}/versions?filters%5Bversion_type%5D=tagged)"
        f" and [Docker Hub]({DOCKERHUB_PAGE}/tags?name={args.tag}) -"
        f" `docker pull {GHCR_REFERENCE}:{args.tag}`",
        "",
    ]
    # The promotion record lands on main only when the candidate merges,
    # so an rc cannot link it - once promoted, its banner points at the release, which can.
    if not re.search(r"-rc\.\d+$", args.tag):
        out += [
            f"Scripts can read the promotion record, the manifest digest of every stage:"
            f" [releases/{args.tag}.yaml]"
            f"({REPOSITORY_PAGE}/blob/main/releases/{args.tag}.yaml)",
            "",
        ]
    out += [
        "### Toolchain versions",
        "",
        "| Component | Version |",
        "| --- | --- |",
    ]
    out += [f"| {labels.get(name, name)} | `{render_version(current[name], schemes.get(name))}` |" for name in ordered]
    out += [
        "",
        "Every version listed above is pinned in the [Dockerfile](Dockerfile) and kept current by Renovate.  ",
        "GCC and Clang pin a major and install from rolling apt sources, so their patch level is the one those sources served on the build date.  ",
        "What a pinned version does and does not fix: [Tags & versioning](README.md#whats-inside-a-given-tag).",
    ]

    if diffing:
        out += ["", f"### Changes since {previous_ref}", ""]
        if undiffable:
            # Never "No component moved." here: that is a claim, and this is the case where nothing is known.
            out.append(f"Not comparable against `{previous_ref}` - {undiffable}.")
        else:
            moved = moved_pins(current, previous)
            if not moved:
                out.append("No component moved.")
            else:
                out += change_lines(moved, labels, ordered, schemes)
                if any(name not in moved for name in ordered):
                    out += ["", "All other components unchanged."]

    out += ["", "<!-- manifest:end -->"]
    print("\n".join(out))


if __name__ == "__main__":
    main()
