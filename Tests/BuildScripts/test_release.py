"""Small, local checks for versioning and release safeguards."""

import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
import build_number
import release


def release_info(draft=False):
    return dict(tag_name="v1.4.0", name="Major Tom 1.4", draft=draft,
                prerelease=False, assets=[], html_url="https://example.invalid/draft")


class ReleaseTests(unittest.TestCase):
    def test_version_numbers(self):
        for bump, expected in (("major", (2, 0, 0)), ("minor", (1, 9, 0)), ("patch", (1, 8, 3))):
            self.assertEqual(release.increment_version((1, 8, 2), bump), expected)
        self.assertEqual(release.increment_version((1, 9, 0), "minor"), (1, 10, 0))
        self.assertEqual(release.display_version((1, 4, 0)), "1.4")
        self.assertEqual(release.display_version((1, 4, 1)), "1.4.1")
        public = release_info()
        pending = dict(public, tag_name="v2.0.0", name="Major Tom 2.0", draft=True)
        self.assertEqual(release.latest_published([pending, public])[0], (1, 4, 0))

    def test_build_numbers_increase_and_channels_are_separate(self):
        Path("/tmp/MajorTom").mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir="/tmp/MajorTom") as directory:
            self.assertEqual(build_number.next_build_number("development", 300, directory), 301)
            self.assertEqual(build_number.next_build_number("development", 300, directory), 302)
            self.assertEqual(build_number.next_build_number("production", 500, directory), 501)
            self.assertEqual(build_number.next_build_number("production", 0, directory), 502)
        pending = dict(release_info(True), body="<!-- major-tom-build: 502 -->")
        self.assertEqual(release.minimum_build_number([pending]), 502)

    def test_published_releases_cannot_be_replaced(self):
        with self.assertRaises(ValueError):
            release.replacement_draft([release_info()], (1, 4, 0), "v1.4.0")
        draft = release_info(True)
        self.assertIs(release.replacement_draft([draft], (1, 4, 0), "v1.4.0"), draft)

    def test_draft_requires_both_completed_uploads(self):
        Path("/tmp/MajorTom").mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir="/tmp/MajorTom") as directory:
            files = tuple(Path(directory) / name for name in ("app.zip", "app.zip.sha256"))
            for path in files:
                path.write_bytes(b"synthetic test data")
            assets = [dict(name=path.name, state="uploaded", size=path.stat().st_size,
                           digest="sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()) for path in files]
            draft = dict(release_info(True), assets=assets)
            self.assertIs(release.verified_draft([draft], (1, 4, 0), "v1.4.0", files), draft)
            draft["assets"] = assets[:1]
            with self.assertRaises(ValueError):
                release.verified_draft([draft], (1, 4, 0), "v1.4.0", files)
            for change in ({"state": "new"}, {"size": 0}, {"digest": "sha256:" + "0" * 64}):
                draft["assets"] = [dict(assets[0], **change), assets[1]]
                with self.assertRaises(ValueError):
                    release.verified_draft([draft], (1, 4, 0), "v1.4.0", files)


if __name__ == "__main__":
    unittest.main()
