#!/usr/bin/env python3
"""Tests for the two scripts the release path depends on: render-manifest.py and check-release-file.py.

Between them they write every public release page and the `bumps:` half of an immutable
releases/v*.yaml record, and until now nothing exercised them outside a real rc build.

Scoped to the behavior the release-note work in #99 changes.
`parse`, `check_supersession` and the `--print-*` accessors are left out on purpose:
nothing there changes them, and asserting that `--print-stages normal` returns the tuple it is
defined as proves nothing.

Fixtures are inline rather than the live Dockerfile and releases/, so a pin bump never turns a
test red.

Usage, from the repository root:
    python3 scripts/details/test-release-tooling.py
"""

import contextlib
import importlib.util
import io
import pathlib
import subprocess
import sys
import tempfile
import unittest

# Importing the two scripts below would drop a scripts/details/__pycache__/ next to the sources,
# on every local run and every CI run - the same reason check-dependencies-pins.py sets this.
sys.dont_write_bytecode = True

HERE = pathlib.Path(__file__).resolve().parent


def load(stem):
    """`<stem>.py` from this directory, imported by path - the hyphen makes it not a module name."""
    spec = importlib.util.spec_from_file_location(stem.replace("-", "_"), HERE / f"{stem}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


render_manifest = load("render-manifest")
check_release_file = load("check-release-file")

DOXYGEN_SCHEME = r"regex:^Release_(?<major>\d+)_(?<minor>\d+)_(?<patch>\d+)$"

DOCKERFILE = """\
ARG UBUNTU_SNAPSHOT=20260825T000000Z
# renovate: datasource=github-tags depName=gcc-mirror/gcc extractVersion=^releases/gcc-(?<version>\\d+)\\.\\d+\\.\\d+$
ARG GCC_VERSIONS=15
# renovate: datasource=github-releases depName=doxygen/doxygen versioning=regex:^Release_(?<major>\\d+)_(?<minor>\\d+)_(?<patch>\\d+)$
ARG DOXYGEN_RELEASE=Release_1_18_0
"""

RENOVATE = """\
{
  "customManagers": [
    {
      "customType": "regex",
      "managerFilePatterns": ["/^Dockerfile$/"],
      "matchStrings": [
        "# renovate: datasource=(?<datasource>\\\\S+) depName=(?<depName>\\\\S+)(?: versioning=(?<versioning>\\\\S+))?(?: extractVersion=(?<extractVersion>\\\\S+))?\\\\s+ARG \\\\w+=(?<currentValue>\\\\S+)"
      ]
    }
  ]
}
"""


def record(**overrides):
    """A schema-valid promotion record, with `overrides` applied."""
    data = {
        "version": "v1.4",
        "candidate": "v1.4-rc.1",
        "commit": "b5d49ffccff2df287a1f0dcc25b318304c6dcc38",
        "digests": {key: f"sha256:{'0' * 64}" for key in check_release_file.expected_digest_keys()},
        "bumps": {},
    }
    data.update(overrides)
    return data


@contextlib.contextmanager
def repository_with_tags(tags):
    """A throwaway git repository carrying `tags`, made current for the duration.

    `newest_release_before` shells out to `git tag -l` in the working directory, so the
    tag-ordering rule can only be exercised against a real repository.
    """
    with tempfile.TemporaryDirectory() as directory:
        def git(*arguments):
            subprocess.run(["git", "-C", directory, *arguments], check=True, capture_output=True)

        git("init", "-q")
        git("config", "user.email", "test@invalid")
        git("config", "user.name", "test")
        git("commit", "-q", "--allow-empty", "-m", "root")
        for tag in tags:
            git("tag", tag)
        with contextlib.chdir(directory):
            yield


def render(*arguments, changelog=None):
    """render-manifest.py over the inline fixtures, in a throwaway directory."""
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        (root / "Dockerfile").write_text(DOCKERFILE, encoding="utf-8")
        (root / "renovate.json").write_text(RENOVATE, encoding="utf-8")
        if changelog is not None:
            (root / "changelog.md").write_text(changelog, encoding="utf-8")
            arguments += ("--changelog", str(root / "changelog.md"))
        done = subprocess.run(
            [sys.executable, str(HERE / "render-manifest.py"),
             "--dockerfile", str(root / "Dockerfile"),
             "--renovate", str(root / "renovate.json"), *arguments],
            capture_output=True, text=True, check=True,
        )
        return done.stdout


class RenderVersion(unittest.TestCase):
    def test_renovate_scheme_names_the_parts(self):
        # Doxygen pins the git tag while the image reports a dotted version.
        self.assertEqual(render_manifest.render_version("Release_1_18_0", DOXYGEN_SCHEME), "1.18.0")

    def test_no_scheme_is_verbatim(self):
        self.assertEqual(render_manifest.render_version("2026.06.24", None), "2026.06.24")
        self.assertEqual(render_manifest.render_version("0.16.0", "loose"), "0.16.0")


class MovedPins(unittest.TestCase):
    def test_repinned(self):
        self.assertEqual(
            render_manifest.moved_pins({"cmake": "4.4.0"}, {"cmake": "4.3.0"}),
            {"cmake": ("4.3.0", "4.4.0")},
        )

    def test_added_and_removed_are_None_on_the_absent_side(self):
        self.assertEqual(
            render_manifest.moved_pins({"new": "1"}, {"gone": "1"}),
            {"gone": ("1", None), "new": (None, "1")},
        )

    def test_unchanged_is_empty(self):
        self.assertEqual(render_manifest.moved_pins({"gcc": "15"}, {"gcc": "15"}), {})


class ChangeLines(unittest.TestCase):
    LABELS = {"gcc-mirror/gcc": "GCC", "doxygen/doxygen": "Doxygen"}
    ORDER = ["gcc-mirror/gcc", "doxygen/doxygen"]

    def test_the_three_forms(self):
        moved = {
            "gcc-mirror/gcc": ("15", "16"),
            "doxygen/doxygen": (None, "Release_1_18_0"),
            "dropped": ("1.0", None),
        }
        self.assertEqual(
            render_manifest.change_lines(moved, self.LABELS, self.ORDER, {}),
            [
                "- GCC: `15` → `16`",
                "- Doxygen: added, `Release_1_18_0`",
                "- dropped: removed, was `1.0`",
            ],
        )

    def test_display_order_wins_over_the_sorted_input(self):
        moved = {"doxygen/doxygen": ("1", "2"), "gcc-mirror/gcc": ("15", "16")}
        lines = render_manifest.change_lines(moved, self.LABELS, self.ORDER, {})
        self.assertEqual([line.split(":")[0] for line in lines], ["- GCC", "- Doxygen"])

    def test_the_renovate_scheme_reaches_the_bullet(self):
        moved = {"doxygen/doxygen": ("Release_1_17_0", "Release_1_18_0")}
        self.assertEqual(
            render_manifest.change_lines(moved, self.LABELS, self.ORDER, {"doxygen/doxygen": DOXYGEN_SCHEME}),
            ["- Doxygen: `1.17.0` → `1.18.0`"],
        )


class BumpsYaml(unittest.TestCase):
    def test_a_depName_with_a_slash_stays_quoted(self):
        # The record is YAML and json.dumps is what keeps this dependency-free.
        self.assertEqual(
            render_manifest.bumps_yaml({"doxygen/doxygen": "Release_1_18_0"},
                                       {"doxygen/doxygen": "Release_1_17_0"}, True),
            'bumps:\n  "doxygen/doxygen": { "from": "Release_1_17_0", "to": "Release_1_18_0" }',
        )

    def test_values_are_the_raw_pin_not_the_rendered_version(self):
        emitted = render_manifest.bumps_yaml({"doxygen/doxygen": "Release_1_18_0"},
                                             {"doxygen/doxygen": "Release_1_17_0"}, True)
        self.assertIn("Release_1_17_0", emitted)
        self.assertNotIn("1.17.0", emitted)

    def test_nothing_moved(self):
        self.assertEqual(render_manifest.bumps_yaml({"gcc": "15"}, {"gcc": "15"}, True), "bumps: {}")

    def test_not_diffing_records_no_bump_even_when_the_sides_differ(self):
        self.assertEqual(render_manifest.bumps_yaml({"gcc": "16"}, {"gcc": "15"}, False), "bumps: {}")


class NewestReleaseBefore(unittest.TestCase):
    TAGS = ["v1.0", "v1.9", "v1.10", "v1.10-rc.1", "v2.0"]

    def test_ordered_on_the_parsed_version_not_lexically(self):
        with repository_with_tags(["v1.9", "v1.10"]):
            self.assertEqual(check_release_file.newest_release_before(""), "v1.10")

    def test_pre_releases_are_not_releases(self):
        with repository_with_tags(["v1.9", "v1.10-rc.1"]):
            self.assertEqual(check_release_file.newest_release_before(""), "v1.9")

    def test_the_tag_being_cut_is_excluded(self):
        with repository_with_tags(self.TAGS):
            self.assertEqual(check_release_file.newest_release_before("v2.0"), "v1.10")

    def test_a_release_after_the_tag_is_not_before_it(self):
        # Re-checking a shipped record must diff against what preceded it. Answering 'v2.0' here is
        # what made `--check-bumps` on releases/v1.2.yaml report a Doxygen downgrade.
        with repository_with_tags(self.TAGS):
            self.assertEqual(check_release_file.newest_release_before("v1.0"), "")
            self.assertEqual(check_release_file.newest_release_before("v1.10"), "v1.9")

    def test_an_rc_orders_as_its_target_minor(self):
        with repository_with_tags(self.TAGS):
            self.assertEqual(check_release_file.newest_release_before("v2.0-rc.1"), "v1.10")

    def test_no_tags_is_the_first_release(self):
        with repository_with_tags([]):
            self.assertEqual(check_release_file.newest_release_before("v1.0"), "")

    def test_an_unreadable_tag_list_raises_rather_than_reading_as_no_releases(self):
        # Otherwise a checkout whose tags were never fetched silently cuts v1.0 over an existing one.
        with tempfile.TemporaryDirectory() as directory, contextlib.chdir(directory):
            with self.assertRaises(SystemExit):
                check_release_file.newest_release_before("v1.0")


class DiffingGuard(unittest.TestCase):
    """The `--previous-ref ''` path: the sanctioned way to ask for a manifest with no diff, and the
    only diffing case reachable without a git checkout."""

    def test_no_previous_ref_renders_no_changes_section(self):
        out = render("--tag", "v1.4", "--previous-ref", "")
        self.assertIn("## What's inside v1.4", out)
        self.assertNotIn("### Changes since", out)

    def test_no_previous_ref_records_no_bump(self):
        self.assertEqual(render("--tag", "v1.4", "--previous-ref", "", "--bumps-yaml").strip(),
                         "bumps: {}")

    def test_the_table_carries_every_pin_including_the_exempt_one(self):
        out = render("--tag", "v1.4", "--previous-ref", "")
        self.assertIn("| `20260825T000000Z` |", out)
        self.assertIn("| GCC | `15` |", out)
        self.assertIn("| Doxygen | `1.18.0` |", out)

    def test_an_unreadable_previous_ref_fails_the_record(self):
        # An unverifiable `bumps: {}` in an immutable record reads exactly like a verified one.
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            render("--tag", "v1.4", "--previous-ref", "v0.0-absent", "--bumps-yaml")
        self.assertIn("::error::cannot diff against v0.0-absent", raised.exception.stderr)

    def test_an_unreadable_previous_ref_is_stated_in_the_note(self):
        out = render("--tag", "v1.4", "--previous-ref", "v0.0-absent")
        self.assertIn("Not comparable against `v0.0-absent`", out)
        self.assertNotIn("No pinned version moved.", out)


class Changelog(unittest.TestCase):
    """What the changelog says is GitHub's answer; where it lands in the note is this script's."""

    BLOCK = ("## What's Changed\n"
             "* a merged pull request by @someone in https://example.invalid/pull/1\n\n"
             "**Full Changelog**: https://example.invalid/compare/v1.3...v1.4")

    def test_it_lands_inside_the_marked_region(self):
        # Outside it, --replace-region would keep the old changelog and stack the new one under it.
        out = render("--tag", "v1.4", "--previous-ref", "", changelog=self.BLOCK)
        region = out.split("<!-- manifest:begin -->")[1].split("<!-- manifest:end -->")[0]
        self.assertIn("**Full Changelog**", region)

    def test_whats_inside_precedes_whats_changed(self):
        out = render("--tag", "v1.4", "--previous-ref", "", changelog=self.BLOCK)
        self.assertLess(out.index("## What's inside v1.4"), out.index("## What's Changed"))


class ReplaceRegion(unittest.TestCase):
    BODY = "Hand-written intro.\n\n<!-- manifest:begin -->\nold table\n<!-- manifest:end -->\n\nTrailing prose."

    def replace(self, body, **kwargs):
        return render_manifest.replace_region(body, kwargs.pop("name", "manifest"),
                                              kwargs.pop("replacement", "NEW"),
                                              kwargs.pop("when_absent", "append"))

    def test_only_the_region_is_replaced(self):
        out = self.replace(self.BODY)
        self.assertIn("Hand-written intro.", out)
        self.assertIn("Trailing prose.", out)
        self.assertIn("NEW", out)
        self.assertNotIn("old table", out)

    def test_absent_region_appends_or_prepends(self):
        self.assertTrue(self.replace("body").endswith("NEW"))
        self.assertTrue(self.replace("body", when_absent="prepend").startswith("NEW"))

    def test_a_missing_end_marker_does_not_eat_the_rest_of_the_body(self):
        # The sed this replaces deleted to end-of-file here, losing every hand-written line.
        with self.assertRaises(SystemExit):
            self.replace("intro\n<!-- manifest:begin -->\ntable\n\nTrailing prose.")

    def test_a_duplicated_region_is_refused(self):
        with self.assertRaises(SystemExit):
            self.replace(self.BODY + "\n" + self.BODY)

    def test_markers_out_of_order_are_refused(self):
        with self.assertRaises(SystemExit):
            self.replace("<!-- manifest:end -->\ntable\n<!-- manifest:begin -->")


class Versions(unittest.TestCase):
    """What the images carry. Collected by cxx-toolchain-versions.sh, recorded, diffed record to record."""

    COLLECTED = {
        "compilers": {"gcc-15": "15.2.0", "clang-22": "22.1.8"},
        "libraries": {
            "libstdc++6": "15",
            "libstdc++6-abi": "GLIBCXX_3.4.34",
            "libstdc++6-cxxabi": "CXXABI_1.3.16",
            "libc++1-22": "22.1.8",
            "libc++1-22-abi": "LIBCPP_ABI_1",
            "libc++1-22-cxxabi": "libc++abi.so.1",
        },
    }

    def emit(self, body):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "versions.txt"
            path.write_text(body, encoding="utf-8")
            return render_manifest.versions_yaml(path)

    def test_fields_survive_a_value_containing_no_separator(self):
        self.assertEqual(render_manifest.read_fields("a=1\n\nb=\nnot a field\n"),
                         {"a": "1", "b": ""})

    def test_both_abi_fields_fold_into_the_row_they_belong_to(self):
        self.assertEqual(
            render_manifest.library_rows(self.COLLECTED["libraries"]),
            [
                ("libc++1-22", "22.1.8", "LIBCPP_ABI_1", "libc++abi.so.1"),
                ("libstdc++6", "15", "GLIBCXX_3.4.34", "CXXABI_1.3.16"),
            ],
        )

    def test_cxxabi_is_not_read_as_the_abi_of_a_package_ending_in_cxx(self):
        # `-cxxabi` also ends in `-abi`, so the shorter suffix would invent `libc++1-22-cxx`.
        packages = [row[0] for row in render_manifest.library_rows(self.COLLECTED["libraries"])]
        self.assertNotIn("libc++1-22-cxx", packages)

    def test_a_package_whose_name_ends_in_a_field_keeps_it(self):
        # Only a suffix whose package was collected too is a companion key.
        self.assertEqual(render_manifest.library_rows({"weird-abi": "1"}), [("weird-abi", "1", "", "")])

    def test_compilers_carry_no_abi_column(self):
        rendered = "\n".join(render_manifest.versions_tables(self.COLLECTED))
        self.assertIn("| Compiler | Version |", rendered)
        self.assertIn("| Library | Version | ABI | C++ ABI |", rendered)

    def test_changes_are_flat_and_in_group_order(self):
        previous = {
            "compilers": dict(self.COLLECTED["compilers"], **{"gcc-15": "15.1.0"}),
            "libraries": dict(self.COLLECTED["libraries"], **{"libstdc++6-abi": "GLIBCXX_3.4.33"}),
        }
        self.assertEqual(
            render_manifest.versions_changes(self.COLLECTED, previous),
            ["- gcc-15: `15.1.0` → `15.2.0`",
             "- libstdc++6-abi: `GLIBCXX_3.4.33` → `GLIBCXX_3.4.34`"],
        )

    def test_nothing_moved_is_no_bullets(self):
        self.assertEqual(render_manifest.versions_changes(self.COLLECTED, self.COLLECTED), [])

    def test_a_group_absent_from_the_previous_record_reads_as_added(self):
        self.assertIn("- gcc-15: added, `15.2.0`", render_manifest.versions_changes(self.COLLECTED, {}))

    def test_an_ungrouped_key_is_refused(self):
        with self.assertRaises(SystemExit):
            self.emit("gcc-15=15.2.0\n")

    def test_an_unknown_group_is_refused(self):
        with self.assertRaises(SystemExit):
            self.emit("compilers.gcc-15=15.2.0\nlibraries.libstdc++6=15\ntools.cmake=4.4.0\n")

    def test_a_group_reporting_nothing_fails_rather_than_recording_an_empty_one(self):
        # An empty group in an immutable record reads exactly like a collection that found nothing.
        with self.assertRaises(SystemExit):
            self.emit("compilers.gcc-15=15.2.0\n")

    def test_the_emitted_mapping_quotes_names_carrying_a_plus(self):
        emitted = self.emit("compilers.gcc-15=15.2.0\nlibraries.libstdc++6=15\n")
        self.assertEqual(
            emitted,
            'versions:\n  compilers:\n    "gcc-15": "15.2.0"\n  libraries:\n    "libstdc++6": "15"',
        )


class Validate(unittest.TestCase):
    def test_a_sound_record_reports_nothing(self):
        self.assertEqual(check_release_file.validate("releases/v1.4.yaml", record()), [])

    def test_every_violation_is_reported_not_only_the_first(self):
        broken = record(version="1.4", commit="abc", digests={})
        errors = check_release_file.validate("releases/1.4.yaml", broken)
        self.assertTrue(any("malformed" in error for error in errors))
        self.assertTrue(any("40-hex" in error for error in errors))
        self.assertTrue(any("missing stages" in error for error in errors))

    def test_the_filename_stem_must_match_the_version(self):
        errors = check_release_file.validate("releases/v9.9.yaml", record())
        self.assertTrue(any("does not match" in error for error in errors))

    def test_a_candidate_promotes_to_its_own_minor(self):
        errors = check_release_file.validate("releases/v1.5.yaml", record(version="v1.5"))
        self.assertTrue(any("neither candidate" in error for error in errors))

    def test_a_major_is_the_sanctioned_mismatch(self):
        self.assertEqual(check_release_file.validate("releases/v2.0.yaml", record(version="v2.0")), [])

    def test_digests_are_checked_in_both_directions(self):
        extra = record()
        extra["digests"]["invented"] = f"sha256:{'0' * 64}"
        self.assertTrue(any("unexpected stages" in error
                            for error in check_release_file.validate("releases/v1.4.yaml", extra)))

    def test_a_digest_must_be_sha256_64_hex(self):
        short = record()
        short["digests"]["dev"] = "sha256:abc"
        self.assertTrue(any("digests.dev" in error
                            for error in check_release_file.validate("releases/v1.4.yaml", short)))

    def test_bumps_shape(self):
        errors = check_release_file.validate("releases/v1.4.yaml",
                                             record(bumps={"gcc": {"from": "15"}}))
        self.assertTrue(any("bumps.gcc" in error for error in errors))

    def test_an_unknown_top_level_key_is_refused(self):
        errors = check_release_file.validate("releases/v1.4.yaml", record(unexpected={}))
        self.assertTrue(any("unknown top-level keys" in error for error in errors))

    def test_versions_is_optional(self):
        # Every record cut before the collector existed has none.
        self.assertEqual(check_release_file.validate("releases/v1.4.yaml", record()), [])

    def test_versions_accepts_a_collected_stage(self):
        sound = record(versions={"compilers": {"gcc-15": "15.2.0"}})
        self.assertEqual(check_release_file.validate("releases/v1.4.yaml", sound), [])

    def test_versions_refuses_a_group_nothing_collects(self):
        errors = check_release_file.validate("releases/v1.4.yaml",
                                             record(versions={"tools": {"cmake": "4.4.0"}}))
        self.assertTrue(any("versions: unexpected groups" in error for error in errors))

    def test_versions_refuses_an_empty_group(self):
        errors = check_release_file.validate("releases/v1.4.yaml", record(versions={"compilers": {}}))
        self.assertTrue(any("versions.compilers: empty" in error for error in errors))

    def test_versions_refuses_a_non_string_value(self):
        errors = check_release_file.validate("releases/v1.4.yaml",
                                             record(versions={"compilers": {"gcc-15": 15}}))
        self.assertTrue(any("versions.compilers.gcc-15" in error for error in errors))


class Targets(unittest.TestCase):
    def test_dev_owns_the_unprefixed_aliases(self):
        self.assertEqual(check_release_file.prefixes("dev"), ["dev-", ""])
        self.assertEqual(check_release_file.prefixes("dev-cross"), ["dev-cross-", "cross-"])

    def test_every_other_stage_is_named_explicitly(self):
        self.assertEqual(check_release_file.prefixes("build"), ["build-"])
        self.assertEqual(check_release_file.prefixes("build-cross"), ["build-cross-"])

    def test_the_plan_covers_every_recorded_stage_and_its_aliases(self):
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            check_release_file.print_targets(record())
        lines = captured.getvalue().splitlines()
        expected = sum(len(check_release_file.prefixes(key))
                       for key in check_release_file.expected_digest_keys())
        self.assertEqual(len(lines), expected)
        self.assertIn(f"sha256:{'0' * 64} v1.4-rc.1 v1.4 latest", lines)
        self.assertIn(f"sha256:{'0' * 64} dev-v1.4-rc.1 dev-v1.4 dev-latest", lines)

    def test_a_records_file_sources_from_its_own_tag(self):
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            check_release_file.print_targets(record(version="v2.0", candidate=None))
        self.assertIn(f"sha256:{'0' * 64} v2.0 v2.0 latest", captured.getvalue().splitlines())


if __name__ == "__main__":
    unittest.main(verbosity=2)
