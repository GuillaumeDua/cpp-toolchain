#!/usr/bin/env python3
"""Assert a built image contains the versions the Dockerfile pins, and the tools it advertises.

The pins are the single source of truth. This reads them through render-manifest.py's `parse()`,
which runs the renovate.json manager regexes - so what Renovate tracks, what check-dependencies-pins.py
enforces, what the release note lists, and what this asserts all come from one definition.
Nothing here restates a version, and neither does probe.sh: the probe reports facts and this decides
whether they are the right ones.

Two halves, deliberately split:
    probe.sh   runs inside the image, holds no version knowledge, asserts nothing
    this file  runs on the host, holds no image knowledge, asserts everything

The split is what makes the no-duplication rule structural instead of a convention:
there is no field in probe.sh to write a version into.

Usage, from the repository root:
    python3 scripts/details/tests/verify-image.py --stage build --image cpp-toolchain:build
    python3 scripts/details/tests/verify-image.py --stage dev --cross --image cpp-toolchain:dev-cross
    python3 scripts/details/tests/verify-image.py --print-expectations --all   # no Docker needed
    python3 scripts/details/tests/verify-image.py --self-test                  # no Docker needed

Exits non-zero and reports every violation it found, rather than only the first.
"""

import argparse
import importlib.util
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
DETAILS = HERE.parent
ROOT = DETAILS.parent.parent

# Importing the sibling scripts below would drop a __pycache__/ next to the sources on every run.
sys.dont_write_bytecode = True

PROBE_MOUNT = "/opt/cpp-toolchain-tests"

# Pins this cannot reach from inside a running container, and why.
# Listed rather than silently skipped, so the coverage report stays honest.
UNCOVERABLE = {
    "romkatv/powerlevel10k": "cloned with --depth 1 --branch, so the checkout carries no tag to read back",
    "build2/build2-toolchain": "opt-in (OPT_IN_INTEGRATE_BUILD2), absent from the published images",
}


def load_by_path(name, filename):
    """Import a sibling script by path - the hyphens make them invalid module names.

    Sharing render-manifest.py's parser is the point: this and the release note must agree about
    what a pin is, or the images get verified against a different list than the one published.
    """
    spec = importlib.util.spec_from_file_location(name, DETAILS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --------------------------------------------------------------------------------------------
# Version handling
# --------------------------------------------------------------------------------------------

# A dotted version token, not preceded or followed by more version characters.
# The lookarounds are what stop `4.4.0` matching inside `4.4.10`, and what stop the `86` in
# `x86_64-linux-gnu-g++` being read as a version.
VERSION_TOKEN = re.compile(r"(?<![\w.])(\d+)\.\d+(?:\.\d+)*(?![\w.])")


def major_of(line):
    """Leading integer of the first dotted version token in a `--version` line, or None."""
    match = VERSION_TOKEN.search(line or "")
    return int(match.group(1)) if match else None


def contains_version(line, version):
    """True when `version` appears in `line` as a whole token.

    Anchored on both sides so a longer version can never satisfy a shorter expectation:
    `1.20` must not be answered by `1.20.1`.
    """
    return re.search(rf"(?<![\w.]){re.escape(version)}(?![\w.])", line or "") is not None


def parse_selector(value):
    """GCC_VERSIONS / LLVM_VERSIONS are selectors, not versions.

    Documented forms (README.md, "Build arguments"): a bare major, a space-separated list, `>=N`,
    `all`, `latest`, `latest-stable`. Only the first two resolve without knowing what the upstream
    repository offered at build time, so the rest are asserted as a constraint instead of a value.

    Returns ("exact", [majors]) | ("atleast", n) | ("dynamic", None) | ("unknown", raw).
    """
    raw = (value or "").strip().strip("'\"")
    if raw in ("all", "latest", "latest-stable"):
        return ("dynamic", None)
    bound = re.fullmatch(r">=\s*(\d+)", raw)
    if bound:
        return ("atleast", int(bound.group(1)))
    if re.fullmatch(r"\d+(?:\s+\d+)*", raw):
        return ("exact", sorted({int(part) for part in raw.split()}))
    return ("unknown", raw)


def majors_from_names(listing, prefix):
    """{15, 13} from a `glob:` report of `g++-15 g++-13`, ignoring anything not `<prefix>-<int>`."""
    if listing in ("", "absent"):
        return set()
    found = set()
    for name in listing.split():
        suffix = name[len(prefix) + 1:] if name.startswith(prefix + "-") else ""
        if suffix.isdigit():
            found.add(int(suffix))
    return found


def normalise_triplet(name):
    """Debian package names cannot contain underscores, so the cross toolchain has two spellings:
    `g++-x86-64-linux-gnu` installs `/usr/bin/x86_64-linux-gnu-g++`.

    Normalising both sides means neither the expectation nor the lookup has to guess which is which,
    and it stays correct if the archive ever renames one.
    """
    return name.replace("_", "-")


# --------------------------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------------------------

class Check:
    """One assertion: the probe keys it needs, what it claims, and how to decide it.

    `verdict` takes the parsed report and returns None when satisfied, or a message describing the
    failure in terms of what was expected and what was found.
    """

    def __init__(self, keys, describe, verdict):
        self.keys = tuple(keys)
        self.describe = describe
        self.verdict = verdict


def expect_version(key, label, expected):
    """`<tool> --version` reports `expected`, matched as a whole token."""
    def verdict(report):
        found = report[key]
        if found == "absent":
            return f"{label}: expected {expected}, but the command is not installed"
        if not contains_version(found, expected):
            return f"{label}: expected {expected}, found {found!r}"
        return None
    return Check([key], f"{label} is {expected}", verdict)


def expect_present(key, label):
    def verdict(report):
        return None if report[key] not in ("absent", "") else f"{label}: expected to be present, found absent"
    return Check([key], f"{label} is present", verdict)


def expect_absent(key, label, why):
    def verdict(report):
        return None if report[key] in ("absent", "") else f"{label}: expected absent ({why}), found {report[key]!r}"
    return Check([key], f"{label} is absent - {why}", verdict)


def expect_equals(key, label, expected):
    def verdict(report):
        found = report[key]
        return None if found == expected else f"{label}: expected {expected!r}, found {found!r}"
    return Check([key], f"{label} is {expected}", verdict)


def expect_prefix(key, label, expected):
    """The oh-my-zsh pin is reported by parse() shortened to 12 characters, the checkout is a full sha."""
    def verdict(report):
        found = report[key]
        if found == "absent":
            return f"{label}: expected {expected}..., found absent"
        if not found.startswith(expected):
            return f"{label}: expected {expected}..., found {found!r}"
        return None
    return Check([key], f"{label} starts with {expected}", verdict)


def compiler_checks(label, driver, glob_pattern, selector):
    """The three claims made about a multi-version compiler family.

    More than one major is installed even at `GCC_VERSIONS=15` - Ubuntu's own g++-13 arrives through
    ordinary transitive dependencies - so this never asserts that a major is absent. What it does
    assert is that every requested major is there, and that the unversioned driver resolves to the
    expected one: a broken update-alternatives registration is exactly the kind of "not what it says
    it is" that nothing else here would notice.
    """
    kind, value = selector
    glob_key = f"glob:{glob_pattern}"
    driver_key = f"cmd:{driver}"
    checks = []

    if kind == "exact":
        for major in value:
            versioned = f"cmd:{driver}-{major}"

            def verdict(report, major=major, versioned=versioned):
                found = report[versioned]
                if found == "absent":
                    return f"{label} {major}: requested but {driver}-{major} is not installed"
                if major_of(found) != major:
                    return f"{label} {major}: {driver}-{major} reports {found!r}"
                return None

            checks.append(Check([versioned], f"{driver}-{major} is installed and reports {major}", verdict))

        expected_default = max(value)

        def default_verdict(report):
            found = report[driver_key]
            if found == "absent":
                return f"{label}: {driver} is not installed"
            if major_of(found) != expected_default:
                return (f"{label}: unversioned {driver} should resolve to {expected_default} "
                        f"(the highest requested), found {found!r}")
            return None

        checks.append(Check([driver_key],
                            f"unversioned {driver} resolves to {expected_default}",
                            default_verdict))

    elif kind == "atleast":
        def atleast_verdict(report, bound=value):
            installed = majors_from_names(report[glob_key], driver)
            if not any(major >= bound for major in installed):
                return f"{label}: selector is >={bound}, installed majors are {sorted(installed) or 'none'}"
            found = report[driver_key]
            if major_of(found) is None or major_of(found) < bound:
                return f"{label}: unversioned {driver} should report >={bound}, found {found!r}"
            return None

        checks.append(Check([glob_key, driver_key],
                            f"at least one {driver}-<N> with N>={value}, and {driver} resolves to one",
                            atleast_verdict))

    else:
        # `all` / `latest` / `latest-stable`, or a form this does not recognise. The build resolved
        # it against the upstream repository, so the only honest claim is that it resolved to
        # something and that the unversioned driver points at one of the results.
        def dynamic_verdict(report):
            installed = majors_from_names(report[glob_key], driver)
            if not installed:
                return f"{label}: no {driver}-<N> installed at all"
            found = report[driver_key]
            if major_of(found) not in installed:
                return (f"{label}: unversioned {driver} reports {found!r}, "
                        f"which is not one of the installed majors {sorted(installed)}")
            return None

        checks.append(Check([glob_key, driver_key],
                            f"{driver} resolves to one of the installed majors (selector is dynamic)",
                            dynamic_verdict))

    return checks


def cross_checks(targets):
    """Cross toolchains, whose version is pinned by nothing.

    binutils.sh installs unversioned `g++-<triplet>` from the Ubuntu archive, so the cross compiler
    is the distro's GCC - determined by UBUNTU_SNAPSHOT, not by GCC_VERSIONS. Asserting it against
    the GCC pin would fail for the wrong reason. What is checkable without inventing a second source
    of truth: every requested triplet is present, and they all agree on a major.

    Presence is the one that matters operationally - binutils.sh installs each target best-effort and
    its skip log is a no-op under the Dockerfile's --silent=yes, so a -cross image that
    cross-compiles nothing currently builds green with no output at all.

    Presence is gated on the installed package, not on the binary being on disk. Debian's multiarch
    layout means `/usr/bin/x86_64-linux-gnu-g++` exists in every image as an alias for the native
    compiler, so a filesystem check would report the x86-64 target as present in a lean image that
    has no cross toolchain at all - passing vacuously on exactly the target most likely to be
    special-cased. The dpkg status database distinguishes them; the filesystem does not.

    Whether the drivers actually work is smoke/cross.sh's question, not this one's.
    """
    package_keys = [f"dpkg:g++-{target}" for target in targets]

    def presence_verdict(report):
        missing = [target for target, key in zip(targets, package_keys) if report[key] == "absent"]
        if missing:
            return f"cross toolchain: package g++-{', g++-'.join(missing)} is not installed"
        return None

    checks = [Check(package_keys,
                    f"a cross g++ package is installed for each of {', '.join(targets)}",
                    presence_verdict)]

    def consistency_verdict(report):
        majors = {}
        for target, key in zip(targets, package_keys):
            found = report[key]
            if found == "absent":
                return None  # already reported by the presence check
            majors[target] = major_of(found)
        if len(set(majors.values())) > 1:
            detail = ", ".join(f"{t}={m}" for t, m in sorted(majors.items()))
            return f"cross toolchain: mixed GCC majors across targets ({detail})"
        return None

    checks.append(Check(package_keys,
                        "all cross toolchains come from the same GCC major",
                        consistency_verdict))
    return checks


# --------------------------------------------------------------------------------------------
# Expectations, per stage
# --------------------------------------------------------------------------------------------

def expectations(stage, cross, pins, cross_targets):
    """[Check] for one stage and variant.

    The stages are a diamond (runtime -> build -> {static-analysis, documentation} -> dev), and dev
    re-adds the documentation tools, so the sets below are cumulative in the same shape.
    """
    ubuntu = pins.get("ubuntu", "")
    snapshot = pins.get("UBUNTU_SNAPSHOT", "")
    doxygen = doxygen_version(pins.get("doxygen/doxygen", ""))

    checks = [
        expect_equals(f"file:/etc/os-release:VERSION_ID", "Ubuntu release", ubuntu),
        expect_equals("apt-src", "apt archive snapshot", snapshot),
    ]

    if stage == "runtime":
        checks += [
            expect_present("lib:libstdc++.so.6", "libstdc++"),
            expect_present("lib:libgcc_s.so.1", "libgcc_s"),
            expect_present("lib:libc.so.6", "libc"),
            # The negatives are the point of the stage: runtime exists to be small enough to ship,
            # and a compiler leaking into it is a regression nothing else would catch.
            expect_absent("cmd:g++", "g++", "runtime ships no toolchain"),
            expect_absent("cmd:cmake", "cmake", "runtime ships no toolchain"),
            expect_absent("cmd:git", "git", "runtime ships no toolchain"),
        ]
        return checks

    gcc = parse_selector(pins.get("gcc-mirror/gcc", ""))
    llvm = parse_selector(pins.get("llvm/llvm-project", ""))

    checks += compiler_checks("GCC", "g++", "/usr/bin/g++-*", gcc)
    checks += compiler_checks("Clang", "clang++", "/usr/bin/clang++-*", llvm)
    checks += [
        expect_version("cmd:cmake", "CMake", pins.get("Kitware/CMake", "")),
        expect_present("cmd:ninja", "ninja"),
        expect_present("cmd:ccache", "ccache"),
        expect_present("cmd:git", "git"),
        expect_present("path:/opt/vcpkg/vcpkg", "vcpkg checkout"),
        expect_version("cmd:vcpkg", "vcpkg", pins.get("microsoft/vcpkg", "")),
        expect_version("cmd:conan", "Conan", pins.get("conan", "")),
    ]

    if stage == "build":
        # build installs clang minimalistically: the clang-tidy-N package is physically present, and
        # only static-analysis registers the unversioned alternative. That boundary is the whole
        # difference between the two stages, and it is invisible to a package listing.
        checks.append(expect_absent("alt:clang-tidy", "clang-tidy",
                                    "build registers compilers only, static-analysis registers the analysers"))

    if stage in ("static-analysis", "dev"):
        checks += [
            expect_present("cmd:clang-tidy", "clang-tidy"),
            expect_present("cmd:clang-format", "clang-format"),
            expect_present("cmd:clangd", "clangd"),
            expect_present("cmd:scan-build", "scan-build"),
            expect_present("cmd:lldb", "lldb"),
            expect_present("cmd:cppcheck", "cppcheck"),
            # The package is `iwyu`, the binary it installs is `include-what-you-use`.
            expect_present("cmd:include-what-you-use", "include-what-you-use"),
        ]

    if stage in ("documentation", "dev"):
        checks += [
            expect_version("cmd:doxygen", "Doxygen", doxygen),
            expect_present("cmd:dot", "graphviz (dot)"),
            expect_present("cmd:lcov", "lcov"),
            expect_present("cmd:genhtml", "genhtml"),
        ]

    if stage == "documentation":
        checks += [
            expect_present("cmd:llvm-cov", "llvm-cov"),
            expect_present("cmd:llvm-profdata", "llvm-profdata"),
        ]

    if stage == "dev":
        checks += [
            expect_present("cmd:valgrind", "valgrind"),
            expect_present("cmd:gdb", "gdb"),
            expect_present("cmd:svn", "subversion"),
            expect_present("cmd:jq", "jq"),
            expect_present("cmd:rg", "ripgrep"),
            expect_present("cmd:zsh", "zsh"),
            expect_prefix("git:/root/.oh-my-zsh", "oh-my-zsh checkout",
                          pins.get("https://github.com/ohmyzsh/ohmyzsh", "")),
            expect_present("path:/root/.oh-my-zsh/custom/themes/powerlevel10k", "powerlevel10k checkout"),
            expect_present("grep:/root/.zshrc:powerlevel10k/powerlevel10k", "powerlevel10k theme in .zshrc"),
        ]

    if cross:
        checks += cross_checks(cross_targets)

    return checks


def doxygen_version(release_tag):
    """`Release_1_17_0` -> `1.17.0`. The tag is what Renovate tracks; the binary reports the dotted form."""
    return release_tag.replace("Release_", "").replace("_", ".") if release_tag else ""


# Image config, read with `docker inspect` rather than from inside the container.
# Every stage ends with `CMD ["/bin/bash"]`, and none of them set a WORKDIR or USER that survives -
# so a change to any of these is a change to how every consumer's `docker run` behaves.
METADATA = (
    ("Cmd", ["/bin/bash"], "default command"),
    ("WorkingDir", "", "working directory"),
    ("User", "", "user"),
)


# --------------------------------------------------------------------------------------------
# Running against an image
# --------------------------------------------------------------------------------------------

def run_probe(image, keys):
    """Execute probe.sh inside `image` and return {key: value}.

    The tests directory is bind-mounted rather than COPYed in: scripts/details is excluded from the
    build context (.dockerignore), so nothing here can accidentally become part of an image.
    """
    command = [
        "docker", "run", "--rm",
        "--volume", f"{HERE}:{PROBE_MOUNT}:ro",
        image,
        "bash", f"{PROBE_MOUNT}/probe.sh", *keys,
    ]
    completed = subprocess.run(command, capture_output=True, text=True)
    if completed.returncode != 0:
        raise SystemExit(f"::error::probe failed in {image}: {completed.stderr.strip()}")
    return parse_report(completed.stdout)


def parse_report(text):
    report = {}
    for line in text.splitlines():
        if "\t" not in line:
            continue
        key, _, value = line.partition("\t")
        report[key] = value
    return report


def inspect_metadata(image):
    completed = subprocess.run(
        ["docker", "inspect", "--format", "{{json .Config}}", image],
        capture_output=True, text=True,
    )
    if completed.returncode != 0:
        raise SystemExit(f"::error::docker inspect failed for {image}: {completed.stderr.strip()}")
    return json.loads(completed.stdout)


def evaluate(checks, report):
    """[message] for every failed check, plus every key the probe did not answer.

    A key that came back `unsupported-key`, or did not come back at all, is a bug in this suite
    rather than in the image - reported as such so the two are never confused.
    """
    problems = []
    for check in checks:
        missing = [key for key in check.keys if key not in report]
        unsupported = [key for key in check.keys if report.get(key) == "unsupported-key"]
        if missing:
            problems.append(f"[suite] probe did not report {', '.join(missing)}")
            continue
        if unsupported:
            problems.append(f"[suite] probe does not understand {', '.join(unsupported)}")
            continue
        failure = check.verdict(report)
        if failure:
            problems.append(failure)
    return problems


def verify(stage, cross, image, pins, cross_targets):
    checks = expectations(stage, cross, pins, cross_targets)
    keys = sorted({key for check in checks for key in check.keys})
    report = run_probe(image, keys)
    problems = evaluate(checks, report)

    config = inspect_metadata(image)
    for name, expected, label in METADATA:
        found = config.get(name)
        if found != expected:
            problems.append(f"image {label}: expected {expected!r}, found {found!r}")

    return checks, problems


# --------------------------------------------------------------------------------------------
# Self-test - the suite gates every release, so it does not ship untested
# --------------------------------------------------------------------------------------------

SELF_TEST_PINS = {
    "ubuntu": "24.04",
    "UBUNTU_SNAPSHOT": "20260720T000000Z",
    "gcc-mirror/gcc": "15",
    "llvm/llvm-project": "22",
    "Kitware/CMake": "4.4.0",
    "microsoft/vcpkg": "2026.06.24",
    "conan": "2.31.1",
    "doxygen/doxygen": "Release_1_17_0",
    "https://github.com/ohmyzsh/ohmyzsh": "7ea697fd8138",
}

SELF_TEST_TARGETS = ("x86-64-linux-gnu", "aarch64-linux-gnu")


def good_build_report():
    """A report from an image that is exactly what it claims to be."""
    return {
        "file:/etc/os-release:VERSION_ID": "24.04",
        "apt-src": "20260720T000000Z",
        "glob:/usr/bin/g++-*": "g++-13 g++-15",
        "glob:/usr/bin/clang++-*": "clang++-22",
        "cmd:g++": "g++ (Ubuntu 15.1.0-1ubuntu1~24.04) 15.1.0",
        "cmd:g++-15": "g++-15 (Ubuntu 15.1.0-1ubuntu1~24.04) 15.1.0",
        "cmd:clang++": "Ubuntu clang version 22.1.0-++20260101",
        "cmd:clang++-22": "Ubuntu clang version 22.1.0-++20260101",
        "cmd:cmake": "cmake version 4.4.0",
        "cmd:ninja": "1.11.1",
        "cmd:ccache": "ccache version 4.9.1",
        "cmd:git": "git version 2.43.0",
        "path:/opt/vcpkg/vcpkg": "present",
        "cmd:vcpkg": "vcpkg package management program version 2026.06.24",
        "cmd:conan": "Conan version 2.31.1",
        "alt:clang-tidy": "absent",
    }


def cross_report():
    report = good_build_report()
    report.update({
        "dpkg:g++-x86-64-linux-gnu": "4:13.2.0-7ubuntu1",
        "dpkg:g++-aarch64-linux-gnu": "4:13.2.0-7ubuntu1",
    })
    return report


def helper_test():
    """Direct assertions on the version helpers.

    End-to-end fixtures alone are too coarse here: an earlier revision of this suite passed its whole
    fixture set with the version anchoring removed, because no fixture happened to distinguish the
    two. These cases are chosen so each one fails if its specific rule is dropped.
    """
    failures = []

    def case(label, actual, expected, want):
        got = contains_version(actual, expected)
        if got is not want:
            failures.append(f"contains_version({actual!r}, {expected!r}) -> {got}, expected {want}")

    # The rule the whole design rests on: a longer version must never satisfy a shorter expectation.
    case("longer patch", "cmake version 3.28.10", "3.28.1", False)
    case("longer minor", "powerlevel10k 1.20.1", "1.20", False)
    case("leading digits", "cmake version 14.4.0", "4.4.0", False)
    case("exact", "cmake version 4.4.0", "4.4.0", True)
    case("trailing build metadata", "Conan version 2.31.1", "2.31.1", True)
    case("dotted date", "vcpkg ... version 2026.06.24", "2026.06.24", True)

    majors = {
        # The `86` in x86_64 must not be read as a version - this is what makes the cross drivers
        # safe to interrogate with the same helper as the host compilers.
        "x86_64-linux-gnu-g++ (Ubuntu 13.3.0-6ubuntu2~24.04) 13.3.0": 13,
        "g++ (Ubuntu 15.1.0-1ubuntu1~24.04) 15.1.0": 15,
        "Ubuntu clang version 22.1.0-++20260101": 22,
        "4:13.2.0-7ubuntu1": 13,
        "no version here": None,
    }
    for line, want in majors.items():
        got = major_of(line)
        if got != want:
            failures.append(f"major_of({line!r}) -> {got}, expected {want}")

    selectors = {
        "15": ("exact", [15]),
        "9 11 13": ("exact", [9, 11, 13]),
        ">=13": ("atleast", 13),
        "all": ("dynamic", None),
        "latest-stable": ("dynamic", None),
    }
    for raw, want in selectors.items():
        got = parse_selector(raw)
        if got != want:
            failures.append(f"parse_selector({raw!r}) -> {got}, expected {want}")

    if normalise_triplet("x86_64-linux-gnu-g++") != "x86-64-linux-gnu-g++":
        failures.append("normalise_triplet does not reconcile the x86_64 / x86-64 spellings")

    return failures


def self_test():
    """Every case below must fail. A verifier that cannot fail is not verifying anything."""
    failures = helper_test()

    def expect_rejected(name, stage, cross, report, targets=SELF_TEST_TARGETS, pins=None):
        checks = expectations(stage, cross, pins or SELF_TEST_PINS, targets)
        problems = evaluate(checks, report)
        if not problems:
            failures.append(f"{name}: expected a violation, found none")

    def expect_accepted(name, stage, cross, report, targets=SELF_TEST_TARGETS, pins=None):
        checks = expectations(stage, cross, pins or SELF_TEST_PINS, targets)
        problems = evaluate(checks, report)
        if problems:
            failures.append(f"{name}: expected no violation, found {problems}")

    expect_accepted("a correct build image passes", "build", False, good_build_report())
    expect_accepted("a correct cross image passes", "build", True, cross_report())

    stale = good_build_report()
    stale["cmd:cmake"] = "cmake version 4.3.9"
    expect_rejected("a stale CMake is caught", "build", False, stale)

    # A longer version must not satisfy a shorter expectation. The pinned 4.4.0 cannot express this
    # (no digit can be appended to it that leaves 4.4.0 a substring), so the case pins 4.4.1 and
    # answers with 4.4.10 - the exact shape the anchoring exists to reject.
    near_miss = good_build_report()
    near_miss["cmd:cmake"] = "cmake version 4.4.10"
    expect_rejected("4.4.10 does not satisfy 4.4.1", "build", False, near_miss,
                    pins={**SELF_TEST_PINS, "Kitware/CMake": "4.4.1"})

    wrong_default = good_build_report()
    wrong_default["cmd:g++"] = "g++ (Ubuntu 13.3.0-6ubuntu2~24.04) 13.3.0"
    expect_rejected("a mis-registered g++ alternative is caught", "build", False, wrong_default)

    missing_major = good_build_report()
    missing_major["cmd:g++-15"] = "absent"
    missing_major["glob:/usr/bin/g++-*"] = "g++-13"
    expect_rejected("a requested major that is not installed is caught", "build", False, missing_major)

    absent_tool = good_build_report()
    absent_tool["cmd:conan"] = "absent"
    expect_rejected("a tool missing from PATH is caught", "build", False, absent_tool)

    leaked = {
        "file:/etc/os-release:VERSION_ID": "24.04",
        "apt-src": "20260720T000000Z",
        "lib:libstdc++.so.6": "present",
        "lib:libgcc_s.so.1": "present",
        "lib:libc.so.6": "present",
        "cmd:g++": "g++ (Ubuntu 15.1.0) 15.1.0",
        "cmd:cmake": "absent",
        "cmd:git": "absent",
    }
    expect_rejected("a compiler leaking into runtime is caught", "runtime", False, leaked)

    missing_triplet = cross_report()
    missing_triplet["dpkg:g++-aarch64-linux-gnu"] = "absent"
    expect_rejected("a silently skipped cross target is caught", "build", True, missing_triplet)

    # Debian multiarch puts /usr/bin/x86_64-linux-gnu-g++ in every image as an alias for the native
    # compiler, so a filesystem check would call the x86-64 target present in a lean image with no
    # cross toolchain at all. The package is what distinguishes them.
    native_alias_only = cross_report()
    native_alias_only["dpkg:g++-x86-64-linux-gnu"] = "absent"
    expect_rejected("the native multiarch alias does not count as a cross toolchain",
                    "build", True, native_alias_only)

    mixed = cross_report()
    mixed["dpkg:g++-aarch64-linux-gnu"] = "4:14.2.0-1ubuntu1"
    expect_rejected("cross toolchains disagreeing on a major are caught", "build", True, mixed)

    # The x86-64 / x86_64 spelling is the one that would survive review: three of four triplets are
    # unaffected, and only this one needs the package name and the binary name to be reconciled.
    expect_accepted("the x86-64 triplet resolves to x86_64-linux-gnu-g++", "build", True, cross_report())

    unsupported = good_build_report()
    unsupported["cmd:cmake"] = "unsupported-key"
    expect_rejected("a probe key the probe cannot answer is reported", "build", False, unsupported)

    dynamic = good_build_report()
    dynamic["cmd:g++"] = "g++ (Ubuntu 11.4.0) 11.4.0"
    expect_rejected("a >=13 selector rejects an 11 default", "build", False, dynamic,
                    pins={**SELF_TEST_PINS, "gcc-mirror/gcc": ">=13"})

    # probe.sh must hold no version knowledge - the structural half of the no-duplication rule.
    probe = (HERE / "probe.sh").read_text(encoding="utf-8") if (HERE / "probe.sh").exists() else ""
    for lineno, line in enumerate(probe.split("\n"), start=1):
        if re.search(r"(?<![\w.])\d+\.\d+(?![\w.])", line):
            failures.append(f"probe.sh:{lineno}: contains what looks like a version - {line.strip()!r}")

    return failures


# --------------------------------------------------------------------------------------------

def report(problems, on_actions):
    for message in problems:
        if on_actions:
            print(f"::error::{message}")
        else:
            print(f"error: {message}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stage", help="stage to verify (runtime, build, static-analysis, documentation, dev)")
    parser.add_argument("--image", help="image reference or digest to verify")
    parser.add_argument("--cross", action="store_true", help="the image is a -cross variant")
    parser.add_argument("--all", action="store_true", help="with --print-expectations: every stage and variant")
    parser.add_argument("--print-expectations", action="store_true",
                        help="list what would be asserted, without running Docker")
    parser.add_argument("--self-test", action="store_true",
                        help="run the assertion engine against fixture reports, without running Docker")
    parser.add_argument("--dockerfile", default=str(ROOT / "Dockerfile"))
    parser.add_argument("--renovate", default=str(ROOT / "renovate.json"))
    args = parser.parse_args()

    on_actions = bool(os.environ.get("GITHUB_ACTIONS"))

    if args.self_test:
        failures = self_test()
        report(failures, on_actions)
        if failures:
            return 1
        print("self-test passed - every fixture that should fail does, and the sound ones do not")
        return 0

    render_manifest = load_by_path("render_manifest", "render-manifest.py")
    release_file = load_by_path("check_release_file", "check-release-file.py")
    pins = render_manifest.parse(
        pathlib.Path(args.dockerfile).read_text(encoding="utf-8"),
        pathlib.Path(args.renovate).read_text(encoding="utf-8"),
    )
    if not pins:
        raise SystemExit("::error::no pinned versions found - has the Dockerfile or renovate.json changed shape?")
    cross_targets = list(release_file.CROSS_TARGETS)

    if args.print_expectations:
        stages = release_file.NORMAL_STAGES if args.all else [args.stage]
        if not args.all and not args.stage:
            parser.error("--print-expectations needs --stage or --all")
        for stage in stages:
            variants = [False, True] if (args.all and stage in release_file.CROSS_STAGES) else [args.cross]
            for cross in variants:
                title = f"{stage}{'-cross' if cross else ''}"
                checks = expectations(stage, cross, pins, cross_targets)
                print(f"\n{title} - {len(checks)} check(s)")
                for check in checks:
                    print(f"  - {check.describe}")
        return 0

    if not args.stage or not args.image:
        parser.error("--stage and --image are both required")

    checks, problems = verify(args.stage, args.cross, args.image, pins, cross_targets)
    report(problems, on_actions)
    if problems:
        return 1

    covered = sorted(name for name in pins if name not in UNCOVERABLE)
    print(f"{args.stage}{'-cross' if args.cross else ''}: {len(checks)} check(s) passed "
          f"against {args.image}")
    print(f"pins reachable from a running container: {len(covered)}/{len(pins)}")
    for name, why in sorted(UNCOVERABLE.items()):
        if name in pins:
            print(f"  not covered - {name}: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
