#!/usr/bin/env python3
"""Validate a releases/v*.yaml promotion record, and derive the promotion plan from it.

A releases/v*.yaml file is the reviewed, in-git record of a promotion:

- which rc it came from
- the exact commit that was built
- the manifest digest of every stage that was pushed

Merging it to main is what promotes - so this file is the single place its schema is known, and everything that reads or writes one goes through here.

The stage lists are the canonical ones (--print-stages) - docker-publish.yml reads them from this script rather than restating them,
so the digests recorded by the rc build and the targets derived at promotion cannot drift apart.

Usage, from the repository root - the git checks and the bumps recompute both read the worktree:
    python3 scripts/details/check-release-file.py releases/v1.2.yaml                      # schema only (offline)
    python3 scripts/details/check-release-file.py releases/v1.2.yaml --check-supersession # newest-rc assert, tags on stdin
    python3 scripts/details/check-release-file.py releases/v1.2.yaml --check-git          # candidate tag / commit / main
    python3 scripts/details/check-release-file.py releases/v1.2.yaml --check-bumps        # bumps == render-manifest recompute
    python3 scripts/details/check-release-file.py releases/v1.2.yaml --print-targets      # promotion plan, one line per prefix
    python3 scripts/details/check-release-file.py releases/v1.2.yaml --print-digest dev   # one recorded digest
    python3 scripts/details/check-release-file.py releases/v1.2.yaml --print-commit       # the recorded commit
    python3 scripts/details/check-release-file.py --print-stages normal|cross             # canonical stage lists
    python3 scripts/details/check-release-file.py --print-cross-targets                   # canonical cross triplets

Exits non-zero and reports every violation it found, rather than only the first.
"""

import argparse
import pathlib
import re
import subprocess
import sys

sys.dont_write_bytecode = True

HERE = pathlib.Path(__file__).resolve().parent

# The canonical stage lists. docker-publish.yml consumes these via --print-stages:
# the build loop, the digests recorded per rc, and the targets derived per promotion all come from this one definition.
NORMAL_STAGES = ("runtime", "build", "static-analysis", "documentation", "dev")
CROSS_STAGES = ("build", "static-analysis", "documentation", "dev")  # runtime has no toolchain -> no cross variant

# The cross-arch target triplets the `-cross` variant is built with, canonical for the same reason:
# the build loop, the verification suite and the cross smoke test must request the same list,
# and it was previously restated in both workflows, each labelled a single source of truth.
#   Spelled the Debian way (`x86-64`, not `x86_64`): this is the `g++-<triplet>` package suffix, and
#   Debian package names cannot contain underscores. The installed binary uses the GNU spelling
#   (`/usr/bin/x86_64-linux-gnu-g++`), so anything mapping between the two must normalise.
CROSS_TARGETS = ("x86-64-linux-gnu", "aarch64-linux-gnu", "arm-linux-gnueabihf", "riscv64-linux-gnu")

VERSION_RE = re.compile(r"^v\d+\.\d+$")
CANDIDATE_RE = re.compile(r"^(v\d+\.\d+)-rc\.(\d+)$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")

TOP_LEVEL_KEYS = {"version", "candidate", "commit", "digests", "bumps"}


def expected_digest_keys():
    return tuple(NORMAL_STAGES) + tuple(f"{stage}-cross" for stage in CROSS_STAGES)


def prefixes(key):
    """Image-tag prefixes owned by one digests key. `dev` is the Dockerfile's default target,
    so it also answers to the unprefixed aliases (v1.2 / latest, cross-v1.2 / cross-latest)."""
    if key.endswith("-cross"):
        stage = key[: -len("-cross")]
        out = [f"{stage}-cross-"]
        if stage == "dev":
            out.append("cross-")
        return out
    out = [f"{key}-"]
    if key == "dev":
        out.append("")
    return out


def load(path):
    try:
        import yaml
    except ImportError:
        raise SystemExit("::error::PyYAML is required (python3-yaml)")
    data = yaml.safe_load(pathlib.Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"::error::{path}: expected a YAML mapping at the top level")
    return data


def validate(path, data):
    """Schema-only checks - everything that needs neither git nor a registry."""
    errors = []

    unknown = set(data) - TOP_LEVEL_KEYS
    if unknown:
        errors.append(f"unknown top-level keys: {', '.join(sorted(unknown))}")
    for key in ("version", "commit", "digests", "bumps"):
        if key not in data:
            errors.append(f"missing required key: {key}")

    version = data.get("version", "")
    if version and not VERSION_RE.match(str(version)):
        errors.append(f"version '{version}' is malformed - expected v<major>.<minor>")
    stem = pathlib.Path(path).stem
    if version and stem != version:
        errors.append(f"filename stem '{stem}' does not match version '{version}'")

    candidate = data.get("candidate")
    if candidate is not None:
        match = CANDIDATE_RE.match(str(candidate))
        if not match:
            errors.append(f"candidate '{candidate}' is malformed - expected v<major>.<minor>-rc.<n>")
        elif version and match.group(1) != version and not str(version).endswith(".0"):
            # A candidate normally promotes to its own target minor.
            # The one sanctioned exception is retitling a candidate to the next major (vX.0) - see docs/RELEASE_PROCESS.md.
            errors.append(f"version '{version}' is neither candidate '{candidate}'s target minor nor a major (vX.0)")

    commit = data.get("commit", "")
    if commit and not COMMIT_RE.match(str(commit)):
        errors.append(f"commit '{commit}' is not a full 40-hex sha")

    digests = data.get("digests")
    if digests is not None:
        if not isinstance(digests, dict):
            errors.append("digests: expected a mapping of stage -> sha256 digest")
        else:
            expected = set(expected_digest_keys())
            missing = expected - set(digests)
            unexpected = set(digests) - expected
            # Equality in both directions: a missing stage must not promote a partial release,
            # and an unexpected key must not mint tags nothing built.
            if missing:
                errors.append(f"digests: missing stages: {', '.join(sorted(missing))}")
            if unexpected:
                errors.append(f"digests: unexpected stages: {', '.join(sorted(unexpected))}")
            for key, value in sorted(digests.items()):
                if not DIGEST_RE.match(str(value)):
                    errors.append(f"digests.{key}: '{value}' is not a sha256:<64-hex> digest")

    bumps = data.get("bumps")
    if bumps is not None and not isinstance(bumps, dict):
        errors.append("bumps: expected a mapping (may be empty)")
    if isinstance(bumps, dict):
        for name, move in sorted(bumps.items()):
            if not isinstance(move, dict) or set(move) != {"from", "to"}:
                errors.append(f"bumps.{name}: expected {{ from: ..., to: ... }}")

    return errors


def check_supersession(data, tags):
    """Only the newest rc of a target minor is promotable. Tags come from the caller
    (git tag -l on stdin), so this stays testable offline."""
    candidate = data.get("candidate")
    if candidate is None:
        print("no candidate (records file) - supersession does not apply")
        return []
    minor, number = CANDIDATE_RE.match(str(candidate)).groups()
    rcs = []
    for tag in tags:
        match = re.match(rf"^{re.escape(minor)}-rc\.(\d+)$", tag.strip())
        if match:
            rcs.append(int(match.group(1)))
    if int(number) not in rcs:
        return [f"candidate tag '{candidate}' not found in the tag list"]
    newest = max(rcs)
    if int(number) != newest:
        return [f"'{candidate}' is superseded by '{minor}-rc.{newest}' - promote that, "
                "or revert on main and cut a fresh rc"]
    return []


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout.strip()


def check_git(data):
    """The record must agree with git: the candidate tag points at `commit`, and `commit` is on main."""
    errors = []
    commit = str(data.get("commit", ""))
    candidate = data.get("candidate")
    if candidate is not None:
        try:
            tagged = git("rev-list", "-n1", str(candidate))
        except subprocess.CalledProcessError:
            return [f"candidate tag '{candidate}' does not exist"]
        if tagged != commit:
            errors.append(f"candidate tag '{candidate}' points at {tagged}, not the recorded commit {commit}")
    contained = subprocess.run(
        ["git", "merge-base", "--is-ancestor", commit, "origin/main"], capture_output=True,
    )
    if contained.returncode != 0:
        errors.append(f"commit {commit} is not contained in origin/main")
    return errors


def newest_release_before(version):
    """Newest release tag by version order, excluding rcs and `version` itself."""
    tags = [t for t in git("tag", "-l", "v*.*").splitlines()
            if VERSION_RE.match(t) and t != version]
    if not tags:
        return ""
    return max(tags, key=lambda t: tuple(int(part) for part in t[1:].split(".")))


def check_bumps(data):
    """bumps: is generated, never hand-edited - assert it equals what render-manifest.py
    recomputes between the previous release and the recorded commit."""
    import yaml
    version = str(data.get("version", ""))
    commit = str(data.get("commit", ""))
    previous = newest_release_before(version)
    cmd = [sys.executable, str(HERE / "render-manifest.py"),
           "--tag", version, "--ref", commit, "--bumps-yaml"]
    if previous:
        cmd += ["--previous-ref", previous]
    recomputed = yaml.safe_load(subprocess.run(cmd, capture_output=True, text=True, check=True).stdout)
    expected = recomputed.get("bumps") or {}
    recorded = data.get("bumps") or {}
    if recorded != expected:
        return [f"bumps does not match the recompute against '{previous or '(none)'}': "
                f"recorded {recorded!r}, recomputed {expected!r}"]
    return []


def print_targets(data):
    """The promotion plan: one line per tag prefix - `<digest> <source_tag> <release_tag> <latest_tag>`.
    The source is the candidate's tag when there is one, else the release's own (a records file,
    where re-tagging is a no-op by construction)."""
    version = str(data["version"])
    source_version = str(data.get("candidate") or version)
    for key in expected_digest_keys():
        digest = data["digests"][key]
        for prefix in prefixes(key):
            print(f"{digest} {prefix}{source_version} {prefix}{version} {prefix}latest")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", nargs="?", help="releases/v*.yaml to validate")
    parser.add_argument("--check-supersession", action="store_true",
                        help="assert the candidate is the newest rc of its minor (tag list on stdin)")
    parser.add_argument("--check-git", action="store_true",
                        help="assert the candidate tag points at the recorded commit, contained in origin/main")
    parser.add_argument("--check-bumps", action="store_true",
                        help="assert bumps equals the render-manifest.py recompute at the recorded commit")
    parser.add_argument("--print-targets", action="store_true",
                        help="print the promotion plan (digest, source, release and latest tags)")
    parser.add_argument("--print-digest", metavar="KEY", help="print one recorded digest, e.g. dev")
    parser.add_argument("--print-commit", action="store_true",
                        help="print the recorded commit - the tree the image was built from")
    parser.add_argument("--print-stages", choices=["normal", "cross"],
                        help="print a canonical stage list (no file needed)")
    parser.add_argument("--print-cross-targets", action="store_true",
                        help="print the canonical cross-arch target triplets (no file needed)")
    args = parser.parse_args()

    if args.print_stages:
        print(" ".join(NORMAL_STAGES if args.print_stages == "normal" else CROSS_STAGES))
        return

    if args.print_cross_targets:
        print(" ".join(CROSS_TARGETS))
        return

    if not args.file:
        parser.error("a releases/v*.yaml file is required")

    data = load(args.file)
    errors = validate(args.file, data)
    if not errors and args.check_supersession:
        errors += check_supersession(data, sys.stdin.read().splitlines())
    if not errors and args.check_git:
        errors += check_git(data)
    if not errors and args.check_bumps:
        errors += check_bumps(data)

    if errors:
        for error in errors:
            print(f"::error::{args.file}: {error}")
        raise SystemExit(1)

    if args.print_digest:
        print(data["digests"][args.print_digest])
    elif args.print_commit:
        print(data["commit"])
    elif args.print_targets:
        print_targets(data)
    else:
        print(f"{args.file}: ok")


if __name__ == "__main__":
    main()
