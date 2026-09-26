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
    python3 scripts/details/render-manifest.py --tag v1.2 --changelog changelog.md --versions releases/v1.2.yaml --date 2026-08-25
    python3 scripts/details/render-manifest.py --collected build-metadata/versions/
    python3 scripts/details/render-manifest.py --replace-region manifest --with note.md < body.md
    python3 scripts/details/render-manifest.py --print-date < body.md

`--previous-ref` defaults to the newest release before `--tag`, 
which is the base every caller wants, so no caller computes one.
Pass `--previous-ref ''` for a manifest with no changes section.
A named ref that cannot be read, or that parses to no pins, is never silently rendered as "nothing moved":
- `--bumps-yaml` fails, because an unverifiable `{}` in an immutable record reads as a verified one, and the markdown says it is not comparable.

`--replace-region` edits a release body in place around the `<!-- name:begin -->` markers this
script emits, and refuses an unbalanced pair. Every caller that upserts a release body goes
through it, so hand-written prose outside the region survives a re-run.

`--print-date` reads a date back out of a release body this script wrote, so the heading format has
one owner rather than a copy of it in the caller. A promotion re-run for a rollback re-dates its note
from the release it already published, which has to say the day the release shipped rather than the
day it was restored.

`--changelog` places a block of markdown inside that same region, after the manifest:
- what the repository changed, which only GitHub's generate-notes API can answer.
Fetching it belongs to the caller, which already holds a token - this script reads files and git, and nothing over the network.
Inside the region rather than after it, so a re-run replaces both halves instead of stacking a second changelog under the first.

Which tags count as releases, how they order, and where the images are published are all
check-release-file.py's, read from here rather than restated: the tag docker-publish.yml
publishes, the base this manifest diffs against, and the reference it tells readers to pull cannot disagree.

`--ref` reads the Dockerfile and renovate.json from a git ref instead of the worktree,
so the manifest can be rendered for the exact commit an image was built from,
even when the checkout has moved past it.

`--versions` reads the record being cut: its `versions:` fills the `Installed` column beside the
pins, its `introduced:` fills `Stage introducing`, both diff against the previous release's record,
and its `build` digest is the digest-pinned pull.

`--collected` turns the collection into those two mappings. It takes the directory holding one
`<stage>.txt` per published stage, because which stage first carries a component is a question no
single image can be asked - the stage graph comes from the Dockerfile's own `FROM ... AS` lines.

`--date` stamps the heading with the day the release is produced. Left out, the note carries no
date, so a local render stays byte-comparable with the one before it.

`--bumps-yaml` emits the moved pins as a YAML `bumps:`
- mapping instead of the markdown manifest, the shape recorded in releases/v*.yaml and re-checked by check-release-file.py.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

# Importing check-release-file.py below would drop a scripts/details/__pycache__/ next to the
# sources, on every local run and every CI run.
sys.dont_write_bytecode = True

# Below that line rather than with the imports above it, or the first thing cached is _loader itself.
from _loader import load

HERE = pathlib.Path(__file__).resolve().parent

# depName (or ARG name, for the pins no datasource covers) -> display label, grouped by what a
# reader came to the note for. Anything matched but not listed here still appears, under its raw
# name - so a new pin is never silently dropped from the manifest.
# `shell` is the one group rendered apart: those two pins are a dev-image convenience, and the
# question the note answers is what the toolchain carries.
LABEL_GROUPS = (
    ("base", (
        ("ubuntu", "Ubuntu"),
        ("UBUNTU_SNAPSHOT", "Ubuntu archive snapshot"),
    )),
    ("toolchain", (
        ("gcc-mirror/gcc", "GCC"),
        # The pin drives clang, lld, lldb, clangd and the analysis tools alike, so it is named
        # after the project rather than after the one command it is most often read as.
        ("llvm/llvm-project", "LLVM"),
    )),
    ("build", (
        ("Kitware/CMake", "CMake"),
        ("microsoft/vcpkg", "vcpkg"),
        ("conan", "Conan"),
        ("build2/build2-toolchain", "build2"),
    )),
    ("documentation", (
        ("doxygen/doxygen", "Doxygen"),
    )),
    ("shell", (
        ("https://github.com/ohmyzsh/ohmyzsh", "oh-my-zsh"),
        ("romkatv/powerlevel10k", "powerlevel10k"),
    )),
)

LABELS = [pair for _, pairs in LABEL_GROUPS for pair in pairs]
SHELL_PINS = [name for name, _ in dict(LABEL_GROUPS)["shell"]]

# What a `Pinned` cell says for a component no version pin covers: apt is what fixes its version.
UNPINNED = "apt"

# The pins an image can disagree with, and where the collector answers for them:
# depName -> (group, key template). `{}` takes each major the pin names, so `GCC | 14 15` reads two
# keys and the two table columns line up.
COLLECTED_BY_PIN = {
    "gcc-mirror/gcc": ("compilers", "gcc-{}"),
    "llvm/llvm-project": ("compilers", "clang-{}"),
    "ubuntu": ("distribution", "ubuntu"),
    "UBUNTU_SNAPSHOT": ("distribution", "ubuntu-snapshot"),
    "Kitware/CMake": ("tools", "cmake"),
    "microsoft/vcpkg": ("tools", "vcpkg"),
    "conan": ("tools", "conan"),
    "doxygen/doxygen": ("tools", "doxygen"),
    # build2 is opt-in and off in every published build, so this key is read only where someone
    # turned it on. `bpkg` rather than build2's single-letter `b`, too generic a name for
    # `command -v` to read as an answer about this toolchain.
    "build2/build2-toolchain": ("tools", "bpkg"),
}

# What the published images run on. build-stages.sh passes no `--platform`, so there is exactly one.
PLATFORM = "linux/amd64"


# check-release-file.py owns the version grammar and the registry references:
#   the tag the workflows publish, the base this note diffs against, and the image it tells
#   readers to pull are then one answer rather than three spellings of it.
schema = load("check-release-file")
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


# The heading and its inverse, together so a change to the format lands beside the code reading it.
# docker-publish.yml re-dates a note from the release it already published, which is a read of this
# heading.
HEADING_DATE = re.compile(r"^## What's inside \S+ - (\d{4}-\d{2}-\d{2})[ \t]*$", re.M)


def manifest_heading(tag, date):
    return f"## What's inside {tag}" + (f" - {date}" if date else "")


def date_in_body(body):
    """The date `manifest_heading` stamped into a release body, empty when it carries none."""
    found = HEADING_DATE.search(body)
    return found.group(1) if found else ""


def read_fields(text):
    """`key=value` lines as a mapping - what cxx-toolchain-versions.sh reports, and cxx-stdlibs.sh before it."""
    fields = {}
    for line in text.splitlines():
        name, separator, value = line.strip().partition("=")
        if separator and name:
            fields[name] = value
    return fields


def stage_parents(dockerfile):
    """{stage: parent stage, or None for the root} for every `FROM ... AS <stage>` declared.

    Read out of the Dockerfile rather than declared beside the stage lists: a stage re-parented
    there moves here with it, and the two cannot disagree about which image inherits which.
    A parent the file never declared as a stage - `${BASE_IMAGE}` - is the root of the graph.
    """
    parents = {}
    for parent, stage in re.findall(r"^FROM\s+(\S+)\s+AS\s+(\S+)", dockerfile, re.MULTILINE | re.IGNORECASE):
        parents[stage] = parent if parent in parents else None
    return parents


def collected_by_stage(directory):
    """{stage: {group: {name: value}}} from one `<stage>.txt` per published stage.

    Every published stage must be there: a missing file is a collection that did not run, and an
    absent stage would hand its components to the one above it as though they were introduced there.
    """
    base = pathlib.Path(directory)
    per_stage = {}
    for stage in schema.NORMAL_STAGES:
        source = base / f"{stage}.txt"
        if not source.is_file():
            raise SystemExit(f"::error::{base}: no {source.name} - nothing was collected from {stage}")

        grouped = {}
        for key, value in read_fields(source.read_text(encoding="utf-8")).items():
            group, separator, name = key.partition(".")
            if not separator:
                raise SystemExit(f"::error::{source}: '{key}' carries no group prefix")
            grouped.setdefault(group, {})[name] = value

        unexpected = set(grouped) - set(schema.VERSION_GROUPS)
        if unexpected:
            raise SystemExit(f"::error::{source}: unknown group(s): {', '.join(sorted(unexpected))}")
        per_stage[stage] = grouped
    return per_stage


def merge_collected(per_stage, parents):
    """({group: {name: version}}, {group: {component: [stage]}}) over every stage.

    The two answer different halves. A version is what an image reports, and `-` is a component
    that is installed and cannot state one - vcpkg, conan and doxygen are installed outside apt -
    so it carries a stage and no version, which is why `introduced` is the wider of the two.

    A name collected in several stages must carry the same value in all of them: `documentation`
    and `dev` reporting different doxygen is a build that installed two, which is a fault rather
    than a cell to pick a winner for.
    """
    versions = {}
    for stage in schema.NORMAL_STAGES:
        for group, collected in per_stage[stage].items():
            for name, value in collected.items():
                if value == "-":
                    continue
                seen = versions.setdefault(group, {}).setdefault(name, value)
                if seen != value:
                    raise SystemExit(f"::error::{group}.{name}: collected as '{seen}' and as"
                                     f" '{value}' - one component cannot be two versions")

    # Keyed over every collected name, `-` included, so a component with no version still places.
    everything = {}
    for stage in schema.NORMAL_STAGES:
        for group, collected in per_stage[stage].items():
            everything.setdefault(group, set()).update(collected)

    introduced = {}
    for group, names in everything.items():
        carried = {stage: {split_key(name, names)[0] for name in per_stage[stage].get(group, {})}
                   for stage in schema.NORMAL_STAGES}
        for stage in schema.NORMAL_STAGES:
            parent = parents.get(stage)
            inherited = carried.get(parent, set()) if parent else set()
            for component in sorted(carried[stage] - inherited):
                introduced.setdefault(group, {}).setdefault(component, []).append(stage)

    return versions, introduced


def collected_yaml(versions, introduced):
    """The collection as the `versions:` and `introduced:` mappings a promotion record carries.

    JSON quoting, as bumps_yaml does. Every group must report something: an empty one in an
    immutable record is indistinguishable from a collection that ran and found nothing.
    """
    lines = ["versions:"]
    for group in schema.VERSION_GROUPS:
        if not versions.get(group):
            raise SystemExit(f"::error::the collection reports no {group}")
        lines.append(f"  {group}:")
        lines += [f"    {json.dumps(name)}: {json.dumps(versions[group][name])}"
                  for name in sorted(versions[group])]

    lines.append("introduced:")
    for group in schema.VERSION_GROUPS:
        lines.append(f"  {group}:")
        lines += [f"    {json.dumps(component)}: {json.dumps(' '.join(stages))}"
                  for component, stages in sorted(introduced.get(group, {}).items())]
    return "\n".join(lines)


# How a library's companion keys read once a table has named the package.
FIELD_LABELS = {"abi": "(ABI)", "cxxabi": "(C++ ABI)"}

# The key grammar is the schema's: a record is validated against the same split that reads it here.
split_key = schema.split_key


def library_rows(collected):
    """(package, version, abi, cxxabi) per package, the companion keys folded into their row.

    The record keeps them apart so each moves on its own in a diff; a table reads better paired.
    """
    rows = {}
    for name, value in sorted(collected.items()):
        package, field = split_key(name, collected)
        rows.setdefault(package, {})[field] = value
    return [(package, fields.get("version", ""), fields.get("abi", ""), fields.get("cxxabi", ""))
            for package, fields in sorted(rows.items())]


def collected_keys(name, pinned, versions):
    """(group, [key]) the `Installed` cell of a pin reads, or None for a pin nothing collects.

    A pin naming one major reads that major's key, and check-dependencies-pins.py keeps a pin to
    one token so there is only ever one. The installers also take selectors - `>=15`,
    `latest-stable`, `all` (docs/IMAGES_VALIDATION.md) - which name no major, so those read every
    key the component left in the group, ordered by major rather than as text: `gcc-9` before
    `gcc-10`.
    """
    source = COLLECTED_BY_PIN.get(name)
    if not source:
        return None
    group, template = source
    if "{}" not in template:
        return group, [template]
    if pinned.isdigit():
        return group, [template.format(pinned)]

    prefix = template.format("")
    def by_major(key):
        major = key[len(prefix):]
        return (0, int(major), "") if major.isdigit() else (1, 0, major)

    return group, sorted((key for key in (versions.get(group) or {}) if key.startswith(prefix)),
                         key=by_major)


def installed_cell(name, pinned, versions, introduced, versioning):
    """The `Installed` cell of a pin row.

    Always the value the images reported, equal to the pin or not: a cell left blank beside a
    version reads as "not installed", which for a pinned component is the one thing it never means.
    `-` carries that meaning and only that one - the pin names something no image has.

    A component with a stage and no version is the third case: vcpkg, conan and doxygen are
    installed outside apt, so no package states their version and the pin is the answer. Presence
    is measured either way, which is what separates this from `-`.
    Empty is left for a collection that did not happen at all, which is a local dry run.
    """
    group, keys, components = pin_components(name, pinned, versions)
    if group is None:
        return ""
    collected = versions.get(group)
    if collected is None:
        return ""

    values = [collected[key] for key in keys if key in collected]
    if values:
        return ", ".join(f"`{value}`" for value in values)
    if stage_cell(group, components, introduced):
        return f"`{render_version(pinned, versioning)}`"
    return "-"


def stage_cell(group, components, introduced):
    """The stages introducing any of `components`, deduplicated and in build order.

    A component can be introduced by two stages at once: `static-analysis` and `documentation`
    both branch off `build`, so what either installs is new in both.
    """
    known = (introduced.get(group) or {}) if group else {}
    stages = {stage for component in components for stage in (known.get(component) or "").split()}
    return sorted(stages, key=schema.NORMAL_STAGES.index)


def pin_components(name, pinned, versions):
    """(group, [key], [component]) a pin's cells read, or (None, [], []) for a pin nothing collects.

    The keys are what a version is looked up under, the components what a stage is: a library's
    `-abi` key and its package share one stage and carry two versions.
    """
    source = collected_keys(name, pinned, versions)
    if source is None:
        return None, [], []
    group, keys = source
    return group, keys, [split_key(key, versions.get(group) or {})[0] for key in keys]


def unpinned_rows(current, versions):
    """(group, name, version) for every collected component no pin accounts for.

    Not dropped: the note's subject is what the images carry, and something installed without a
    pin is what a reader cannot learn from the Dockerfile. That is most of the toolchain - the
    LLVM suite, the coverage tools and the analysis tools are all installed by an apt repository
    rather than by a version pin.
    The libraries are left out: they have a table of their own, with the ABI columns a pin row has
    no room for.
    """
    claimed = set()
    for name, pinned in current.items():
        source = collected_keys(name, pinned, versions)
        if source:
            group, keys = source
            claimed |= {(group, key) for key in keys}
    return [(group, key, value)
            for group in ("distribution", "compilers", "tools")
            for key, value in sorted((versions.get(group) or {}).items())
            if (group, key) not in claimed]


def content_table(current, ordered, labels, schemes, versions, introduced):
    """What the release pins, what the images resolved it to, and where each component appears.

    One table rather than two: a pin and its installed value belong on one row, and a component
    with no pin is still part of what the images carry.
    Ordered by the stage that introduces it, so the table reads the way the images are built,
    and within a stage by the declared pin order, so the pinned components lead.
    """
    rows = []

    for position, name in enumerate(ordered):
        group, _, components = pin_components(name, current[name], versions)
        rows.append((stage_cell(group, components, introduced), position,
                     labels.get(name, name),
                     f"`{render_version(current[name], schemes.get(name))}`",
                     installed_cell(name, current[name], versions, introduced, schemes.get(name))))

    for group, name, value in unpinned_rows(current, versions):
        component = split_key(name, versions.get(group) or {})[0]
        rows.append((stage_cell(group, [component], introduced), len(ordered), name,
                     f"`{UNPINNED}`", f"`{value}`" if value != "-" else "-"))

    out = ["| Component | Pinned | Installed | Stage introducing |", "| --- | --- | --- | --- |"]
    for stages, position, label, pinned, installed in sorted(
            rows, key=lambda row: (schema.NORMAL_STAGES.index(row[0][0]) if row[0] else len(schema.NORMAL_STAGES),
                                   row[1], row[2])):
        out.append(f"| {label} | {pinned} | {installed} |"
                   f" {', '.join(f'`{stage}`' for stage in stages)} |")
    return out


def libraries_table(versions, introduced):
    """The standard libraries, with the two ABI levels a binary is linked against.

    A table of their own: they carry no pin, so there is no `Pinned` column for them to sit in.
    """
    libraries = versions.get("libraries") or {}
    if not libraries:
        return []
    out = ["", "| Library | Version | ABI | C++ ABI | Stage introducing |",
           "| --- | --- | --- | --- | --- |"]
    for package, version, abi, cxxabi in library_rows(libraries):
        cells = " | ".join(f"`{field}`" if field else "" for field in (version, abi, cxxabi))
        stages = ", ".join(f"`{stage}`" for stage in stage_cell("libraries", [package], introduced))
        out.append(f"| `{package}` | {cells} | {stages} |")
    return out


def images_table(tag):
    """Every tag this release answers to, one row per published stage.

    Generated from the record's own stage keys, so it cannot name a tag the promotion did not push.
    Only the first tag of a cell is linked - the rest are aliases of the same image, and Docker Hub
    filters tags by substring, so an alias link lands on the page its cell already points at.
    """
    def cell(key):
        tags = [f"{prefix}{tag}" for prefix in schema.prefixes(key)]
        return ", ".join([f"[`{tags[0]}`]({DOCKERHUB_PAGE}/tags?name={tags[0]})"]
                         + [f"`{alias}`" for alias in tags[1:]])

    keys = set(schema.expected_digest_keys())
    out = ["| Stage | Tag | Cross variant |", "| --- | --- | --- |"]
    for stage in schema.NORMAL_STAGES:
        cross = cell(f"{stage}-cross") if f"{stage}-cross" in keys else ""
        out.append(f"| `{stage}` | {cell(stage)} | {cross} |")
    return out


def cross_targets():
    """The triplets the `-cross` images carry, resolved by the script that owns the `common` alias.

    `--list-targets` reads no apt index and needs no root, and the cross build passes that same
    alias as BINUTILS_TARGETS, so the note cannot name a target the build did not install.
    Read from the worktree rather than from `--ref`: it is a build input, not a pin, and the
    promote job renders for a recorded commit while checked out on main.
    """
    script = HERE.parent / "install" / "binutils.sh"
    listed = subprocess.run(["bash", str(script), "--list-targets", "--targets=common"],
                            capture_output=True, text=True)
    if listed.returncode != 0 or not listed.stdout.split():
        raise SystemExit(f"::error::cannot resolve the cross targets - {script.name} --list-targets failed")
    return listed.stdout.split()


def installed_changes(current, previous):
    """A table row per collected value that moved, in group order.

    Flat rather than nested under the group: a collected name already says which one it is in.
    """
    labels = dict(LABELS)
    rows = []
    for group in schema.VERSION_GROUPS:
        now, before = current.get(group) or {}, previous.get(group) or {}
        known = {**before, **now}
        for name, (old, new) in moved_pins(now, before).items():
            if group == "libraries":
                package, field = split_key(name, known)
                label = package if field == "version" else f"{package} {FIELD_LABELS[field]}"
            else:
                label = labels.get(name, name)
            cells = [f"`{value}`" if value is not None else "-" for value in (old, new)]
            rows.append(f"| {label} | {cells[0]} | {cells[1]} |")
    return rows


def introduced_changes(current, previous):
    """A table row per component whose introducing stage moved, in group order.

    Components present on one side only are left out: an arrival or a departure is already a row
    of the table above, and a stage of `-` there would say the same thing twice.
    """
    rows = []
    for group in schema.VERSION_GROUPS:
        now, before = current.get(group) or {}, previous.get(group) or {}
        for name, (old, new) in moved_pins(now, before).items():
            if old is None or new is None:
                continue
            rows.append(f"| {name} | `{old}` | `{new}` |")
    return rows


def load_versions(path):
    """The `versions:` mapping of a promotion record, or {} when it has none."""
    return schema.load(path).get("versions") or {}


def load_introduced(path):
    """The `introduced:` mapping of a promotion record, or {} when it has none."""
    return schema.load(path).get("introduced") or {}


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


def change_rows(moved, labels, order, schemes):
    """A table row per moved pin, in the manifest's display order, dropped pins last.

    A pin present on one side only gets `-` on the other, rather than a word for it.
    """
    names = [name for name in order if name in moved]
    names += [name for name in moved if name not in order]
    rows = []
    for name in names:
        old, new = moved[name]
        versioning = schemes.get(name)
        cells = [f"`{render_version(value, versioning)}`" if value is not None else "-"
                 for value in (old, new)]
        rows.append(f"| {labels.get(name, name)} | {cells[0]} | {cells[1]} |")
    return rows


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
    parser.add_argument("--changelog", metavar="FILE",
                        help="markdown to place inside the marked region, after the manifest")
    parser.add_argument("--collected", metavar="DIR",
                        help="emit one <stage>.txt per published stage as the YAML `versions:`"
                             " and `introduced:` mappings")
    parser.add_argument("--versions", metavar="RECORD",
                        help="promotion record the note reports from: its `versions:` diffed against the"
                             " previous release's, and its `build` digest as the digest-pinned pull")
    parser.add_argument("--date", metavar="YYYY-MM-DD",
                        help="the date the release is produced, for the heading (default: no date)")
    parser.add_argument("--replace-region", metavar="NAME",
                        help="replace the <!-- NAME:begin --> region of a release body read on stdin (no --tag needed)")
    parser.add_argument("--with", dest="replacement", metavar="FILE",
                        help="the replacement block, for --replace-region")
    parser.add_argument("--when-absent", choices=["append", "prepend"], default="append",
                        help="where to put the block when the region is not there yet (default: append)")
    parser.add_argument("--print-date", action="store_true",
                        help="print the date in a release body read on stdin, empty when it carries none (no --tag needed)")
    parser.add_argument("--dockerfile", default="Dockerfile")
    parser.add_argument("--renovate", default="renovate.json")
    args = parser.parse_args()

    if args.replace_region:
        if not args.replacement:
            parser.error("--replace-region needs --with FILE")
        replacement = pathlib.Path(args.replacement).read_text(encoding="utf-8")
        print(replace_region(sys.stdin.read(), args.replace_region, replacement, args.when_absent))
        return

    if args.print_date:
        print(date_in_body(sys.stdin.read()))
        return

    if args.collected:
        dockerfile = git_show(args.ref, args.dockerfile) if args.ref \
            else pathlib.Path(args.dockerfile).read_text(encoding="utf-8")
        if dockerfile is None:
            raise SystemExit(f"::error::cannot read {args.dockerfile} at ref {args.ref}")
        per_stage = collected_by_stage(args.collected)
        print(collected_yaml(*merge_collected(per_stage, stage_parents(dockerfile))))
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

    # The previous record sits beside the one being cut, so the two are read the same way.
    # A release predating the collector has no `versions:`, which is a stated case below rather
    # than an empty diff: nothing moved and nothing is known read identically otherwise.
    record = schema.load(args.versions) if args.versions else {}
    versions = record.get("versions") or {}
    introduced = record.get("introduced") or {}
    previous_versions = {}
    previous_introduced = {}
    if versions and previous_ref:
        previous_record = pathlib.Path(args.versions).parent / f"{previous_ref}.yaml"
        if previous_record.exists():
            previous_versions = load_versions(previous_record)
            previous_introduced = load_introduced(previous_record)

    # The shell pins are rendered under a heading of their own, so they leave the toolchain order.
    ordered = [name for name, _ in LABELS if name in current and name not in SHELL_PINS]
    ordered += sorted(name for name in current if name not in dict(LABELS))
    labels = dict(LABELS)
    targets = cross_targets()

    # GHCR URLs cannot filter versions by tag name (its per-tag pages are keyed by a numeric
    # version id only the Packages API knows), so the closest deep link is the tagged-only view.
    out = [
        "<!-- manifest:begin -->",
        manifest_heading(args.tag, args.date),
        "",
        f"Published to [GHCR]({GHCR_PAGE}/versions?filters%5Bversion_type%5D=tagged)"
        f" and [Docker Hub]({DOCKERHUB_PAGE}/tags?name={args.tag}).",
        "",
        f"The images run on `{PLATFORM}`.",
        "The `-cross` variants compile and link for "
        + ", ".join(f"`{target}`" for target in targets[:-1])
        + f" and `{targets[-1]}`.",
        "",
        "### Images",
        "",
    ]
    out += images_table(args.tag)

    pull = [f"docker pull {GHCR_REFERENCE}:build-{args.tag}  # by tag"]
    build_digest = (record.get("digests") or {}).get("build")
    if build_digest:
        pull.append(f"docker pull {GHCR_REFERENCE}@{build_digest}  # digest-pinned, byte-exact")
    out += ["", "```bash", *pull, "```", ""]

    # The promotion record lands on main only when the candidate merges,
    # so an rc cannot link it - once promoted, its banner points at the release, which can.
    if not re.search(r"-rc\.\d+$", args.tag):
        out.append(f"- Every stage's manifest digest:"
                   f" [releases/{args.tag}.yaml]({REPOSITORY_PAGE}/blob/main/releases/{args.tag}.yaml)")
    out += [
        f"- What each stage carries: [What's inside]({REPOSITORY_PAGE}#whats-inside)",
        f"- What a pin fixes, and what it does not:"
        f" [Tags & versioning]({REPOSITORY_PAGE}#whats-inside-a-given-tag)",
    ]

    if introduced:
        out += ["", "`Stage introducing` names the lowest stage a component appears in."
                    " Every stage above it inherits it."]

    libraries = libraries_table(versions, introduced)
    if libraries:
        out += ["", "### Standard libraries"]
        out += libraries
        out += ["", "`ABI` and `C++ ABI` are read out of the installed shared object."
                    " `libc6` has no C++ ABI to report; `libc++`'s is the SONAME of the separate"
                    " library it loads, `libstdc++`'s a symbol version inside its own."]

    # Folded away, as README.md#whats-inside folds its own matrix: the toolchain is about thirty
    # rows, and a reader who came for the tag needs none of them open.
    out += ["", "### Content", "",
            "<details><summary><b>Full content</b> - what each stage introduces</summary>", ""]
    out += content_table(current, ordered, labels, schemes, versions, introduced)
    out += ["", "</details>"]

    if versions:
        out += ["", "`apt` in the `Pinned` column means the version comes from a repository rather"
                    " than from a pin: the Ubuntu archive snapshot above for distribution packages,"
                    " apt.llvm.org and the toolchain PPA for the compiler-side ones."
                    " `-` in `Installed` means the component is not in any image."]

    shell = [name for name in SHELL_PINS if name in current]
    if shell:
        out += ["", "### Shell", "", "`dev` only, and unrelated to the toolchain.", "",
                "| Component | Pinned |", "| --- | --- |"]
        out += [f"| {labels[name]} | `{render_version(current[name], schemes.get(name))}` |"
                for name in shell]

    if diffing:
        out += ["", f"### Changes since {previous_ref}", ""]
        if undiffable:
            # Never "nothing moved" here: that is a claim, and this is the case where nothing is known.
            out.append(f"Not comparable against `{previous_ref}` - {undiffable}.")
        else:
            moved = moved_pins(current, previous)
            if not moved:
                out.append("No pinned version moved.")
            else:
                out += ["| Pinned | from | to |", "| --- | --- | --- |"]
                out += change_rows(moved, labels, ordered, schemes)

        if versions:
            if not previous_versions:
                out += ["", f"`{previous_ref}` predates installed-version collection,"
                            " so this release sets the baseline."]
            else:
                rows = installed_changes(versions, previous_versions)
                out += ["", "| Installed | from | to |", "| --- | --- | --- |", *rows] if rows \
                    else ["", "No installed version moved."]

                moves = introduced_changes(introduced, previous_introduced)
                if moves:
                    out += ["", "| Stage introducing | from | to |", "| --- | --- | --- |", *moves]

    if args.changelog:
        out += ["", pathlib.Path(args.changelog).read_text(encoding="utf-8").strip()]

    out += ["", "<!-- manifest:end -->"]
    print("\n".join(out))


if __name__ == "__main__":
    main()
