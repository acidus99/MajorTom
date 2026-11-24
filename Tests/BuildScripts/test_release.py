"""Release workflow tests use synthetic GitHub data and never sign or upload."""

from concurrent.futures import ThreadPoolExecutor
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
import build_number
import release

TEMP_ROOT = Path("/tmp/MajorTom")
TEMP_ROOT.mkdir(parents=True, exist_ok=True)


def github_release(tag="v1.3.0", name="Major Tom 1.3", draft=False, body=""):
    return dict(id=10, tag_name=tag, name=name, draft=draft, prerelease=False,
                immutable=False, body=body, updated_at="2026-01-01T00:00:00Z")


class VersionTests(unittest.TestCase):
    def test_explicit_bumps_reset_lower_components_and_compare_numerically(self):
        self.assertEqual(release.increment_version((1, 8, 2), "major"), (2, 0, 0))
        self.assertEqual(release.increment_version((1, 8, 2), "minor"), (1, 9, 0))
        self.assertEqual(release.increment_version((1, 8, 2), "patch"), (1, 8, 3))
        self.assertEqual(release.increment_version((1, 4, 0), "patch"), (1, 4, 1))
        self.assertEqual(release.increment_version((1, 9, 0), "minor"), (1, 10, 0))
        with self.assertRaises(ValueError):
            release.increment_version((1, 4, 0), "automatic")

    def test_historical_titles_replace_date_versions_and_drafts_do_not_advance_public_version(self):
        public = github_release("v2026.10.03", "Major Tom 1.3")
        pending = github_release("v2.0.0", "Major Tom 2.0", draft=True)
        prerelease = github_release("v3.0.0", "Major Tom 3.0")
        prerelease["prerelease"] = True
        self.assertEqual(release.latest_published([pending, public, prerelease]), ((1, 3, 0), public))
        self.assertEqual(release.display_version((1, 3, 0)), "1.3")
        self.assertEqual(release.display_version((1, 3, 1)), "1.3.1")

    def test_unknown_versions_and_disagreeing_titles_fail_instead_of_guessing(self):
        for item in (github_release("v2026.10.03", "Major Tom v2026.10.03"),
                     github_release("v1.4.0", "Major Tom 1.5")):
            with self.assertRaises(ValueError):
                release.latest_published([item])
        for value in ("1.02", "1.2.3.4", "1.2-rc1", "1.2; echo unsafe"):
            self.assertIsNone(release.parse_version(value))

    def test_published_versions_and_ambiguous_drafts_cannot_be_replaced(self):
        published = github_release("v1.4.0", "Major Tom 1.4")
        with self.assertRaisesRegex(ValueError, "already published"):
            release.replacement_draft([published], (1, 4, 0), "v1.4.0")
        draft = dict(published, draft=True)
        with self.assertRaisesRegex(ValueError, "Multiple drafts"):
            release.replacement_draft([draft, draft], (1, 4, 0), "v1.4.0")

    def test_production_build_floor_includes_unpublished_candidates(self):
        items = [github_release(body="<!-- major-tom-build: 300 -->"),
                 github_release(draft=True, body="<!-- major-tom-build: 320 -->")]
        self.assertEqual(release.minimum_build_number(items), 320)

    def test_make_requires_exactly_one_bump_without_executing_recipes(self):
        for goals in (("release",), ("release", "unknown"),
                      ("release", "minor", "patch"), ("release", "minor", "dev"),
                      ("release", "minor", "BUMP=patch")):
            result = subprocess.run(["make", "--dry-run", *goals], cwd=ROOT,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("make release major|minor|patch", result.stderr)
        for bump in ("major", "minor", "patch"):
            result = subprocess.run(["make", "--dry-run", "release", bump], cwd=ROOT,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"Scripts/release.py {bump}", result.stdout)
        result = subprocess.run(["make", "--dry-run", "release", "minor", "RELEASE_BUMP=major"],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Scripts/release.py minor", result.stdout)


class BuildNumberTests(unittest.TestCase):
    def test_counter_survives_independent_calls_and_channel_counters_are_separate(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as temporary:
            self.assertEqual(build_number.next_build_number("development", 264, temporary), 265)
            self.assertEqual(build_number.next_build_number("development", 264, temporary), 266)
            self.assertEqual(build_number.next_build_number("production", 400, temporary), 401)
            self.assertEqual(build_number.next_build_number("production", 0, temporary), 402)
            self.assertEqual(build_number.next_build_number("production", 500, temporary), 501)

    def test_parallel_allocations_do_not_reuse_numbers(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as temporary:
            with ThreadPoolExecutor(max_workers=8) as pool:
                numbers = list(pool.map(lambda _: build_number.next_build_number(
                    "development", directory=temporary), range(24)))
            self.assertEqual(sorted(numbers), list(range(1, 25)))

    def test_corrupt_counter_does_not_silently_reset(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as temporary:
            counter = Path(temporary) / "production.txt"
            counter.write_text("corrupt\n")
            with self.assertRaises(ValueError):
                build_number.next_build_number("production", directory=temporary)
            self.assertEqual(counter.read_text(), "corrupt\n")


class ReleaseWorkflowTests(unittest.TestCase):
    def exercise(self, *, replacing=False, failure=None, changed_draft=False,
                 published_during_build=False, orphan_tag=False):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as temporary:
            root = Path(temporary)
            commit = "a" * 40
            public = github_release("v2026.10.03", "Major Tom 1.3")
            draft = github_release("v1.4.0", "Major Tom 1.4", draft=True,
                                   body="<!-- major-tom-build: 340 -->")
            initial = [public, draft] if replacing else [public]
            fresh = copy.deepcopy(initial)
            if changed_draft:
                fresh[-1]["updated_at"] = "2026-01-02T00:00:00Z"
            if published_during_build:
                fresh.append(github_release("v1.4.0", "Major Tom 1.4"))
            calls = []

            def fake_run(*arguments, capture=True, env=None):
                calls.append(arguments)
                if arguments[:3] == ("gh", "repo", "view"):
                    return "example/MajorTom"
                if arguments[:3] == ("git", "tag", "--list"):
                    return "v1.4.0" if replacing or orphan_tag else ""
                if arguments[0] == "Scripts/notarize-app.sh":
                    if failure == "build":
                        raise subprocess.CalledProcessError(1, arguments)
                    self.assertEqual(env["MAJOR_TOM_MINIMUM_BUILD_NUMBER"], "340" if replacing else "0")
                    directory = root / "Build/Release"
                    bundle = directory / "Major Tom.app/Contents"
                    bundle.mkdir(parents=True)
                    with (bundle / "Info.plist").open("wb") as destination:
                        plistlib.dump(dict(CFBundleShortVersionString="1.4.0", CFBundleVersion="341",
                                          MTBuildChannel="production", MTBuildCommit=commit), destination)
                    archive = directory / "MajorTom-v1.4.0-macos.zip"
                    archive.write_bytes(b"synthetic test archive")
                    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
                    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n")
                if arguments[:3] == ("gh", "api", "repos/example/MajorTom/releases/generate-notes"):
                    self.assertIn(("git", "push", "origin", f"{commit}:refs/heads/main"), calls)
                    return json.dumps(dict(body="Synthetic release notes"))
                if arguments[:3] == ("git", "push", "origin") and failure == "push":
                    raise subprocess.CalledProcessError(1, arguments)
                return ""

            with patch.object(release, "ROOT", root), \
                 patch.object(release, "run", side_effect=fake_run), \
                 patch.object(release, "require_clean_checkout", return_value=("main", commit)), \
                 patch.object(release, "read_releases", side_effect=[initial, fresh]), \
                 patch.object(release, "remote_tag_object", return_value="b" * 40 if replacing else ""), \
                 contextlib.redirect_stdout(io.StringIO()):
                try:
                    release.prepare_release("minor")
                    error = None
                except (ValueError, subprocess.CalledProcessError) as exception:
                    error = exception
            return calls, error

    def test_new_draft_uses_matching_tag_assets_and_version(self):
        calls, error = self.exercise()
        self.assertIsNone(error)
        create = next(call for call in calls if call[:3] == ("gh", "release", "create"))
        self.assertEqual(create[3], "v1.4.0")
        self.assertIn("Major Tom 1.4", create)
        self.assertIn("--draft", create)
        self.assertFalse(any(call[:3] == ("gh", "release", "delete") for call in calls))
        self.assertTrue(any("--force-with-lease=refs/tags/v1.4.0:" in call for call in calls))

    def test_replacement_is_built_before_deleting_draft_and_tag_uses_a_lease(self):
        calls, error = self.exercise(replacing=True)
        self.assertIsNone(error)
        build = next(index for index, call in enumerate(calls) if call[0] == "Scripts/notarize-app.sh")
        delete = next(index for index, call in enumerate(calls) if call[:3] == ("gh", "release", "delete"))
        create = next(index for index, call in enumerate(calls) if call[:3] == ("gh", "release", "create"))
        self.assertLess(build, delete)
        self.assertLess(delete, create)
        self.assertTrue(any(f"--force-with-lease=refs/tags/v1.4.0:{'b' * 40}" in call for call in calls))

    def test_failed_build_or_push_and_concurrent_changes_preserve_existing_draft(self):
        scenarios = [dict(failure="build"), dict(failure="push"),
                     dict(changed_draft=True), dict(published_during_build=True)]
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                calls, error = self.exercise(replacing=True, **scenario)
                self.assertIsNotNone(error)
                self.assertFalse(any(call[:3] == ("gh", "release", "delete") for call in calls))
                self.assertFalse(any(call[:3] == ("git", "tag", "--force") for call in calls))

    def test_existing_tag_without_draft_stops_before_building(self):
        calls, error = self.exercise(orphan_tag=True)
        self.assertIsNotNone(error)
        self.assertFalse(any(call[0] in ("make", "Scripts/notarize-app.sh") for call in calls))


if __name__ == "__main__":
    unittest.main()
