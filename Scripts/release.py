#!/usr/bin/env python3
"""Build a notarized candidate and create or replace its GitHub draft release.

Human-run only, through `make release major|minor|patch`.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

from build_number import state_directory


ROOT = Path(__file__).resolve().parent.parent
VERSION_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?"
BUILD_MARKER = r"<!-- major-tom-build: ([1-9][0-9]*) -->"


def parse_version(value):
    match = re.fullmatch(VERSION_PATTERN, value)
    return tuple(int(part or 0) for part in match.groups()) if match else None


def display_version(version):
    major, minor, patch = version
    return f"{major}.{minor}" + (f".{patch}" if patch else "")


def increment_version(version, bump):
    major, minor, patch = version
    if bump == "major":
        return major + 1, 0, 0
    if bump == "minor":
        return major, minor + 1, 0
    if bump == "patch":
        return major, minor, patch + 1
    raise ValueError("Choose exactly one of major, minor, or patch")


def release_version(release):
    # Historical date tags and binaries stay intact; their renamed titles own
    # the retrospective version. New releases use matching three-part tags.
    tag = release["tag_name"]
    title = re.fullmatch(r"Major Tom v?(" + VERSION_PATTERN + r")", release["name"] or "")
    title_version = parse_version(title.group(1)) if title else None
    if re.match(r"v?20[0-9]{2}\.", tag):
        return title_version if title_version and title_version[0] < 2000 else None
    tag_version = parse_version(tag.removeprefix("v"))
    if tag_version and title_version and tag_version != title_version:
        raise ValueError(f"Release title and tag disagree: {tag}")
    return tag_version or title_version


def latest_published(releases):
    published = [item for item in releases if not item["draft"] and not item["prerelease"]]
    versions = [(release_version(item), item) for item in published]
    if any(version is None for version, _ in versions):
        raise ValueError("A public release has no recognized version; label it before releasing")
    if not versions:
        raise ValueError("No numbered public release found; label the historical releases first")
    return max(versions, key=lambda pair: pair[0])


def replacement_draft(releases, version, tag):
    matches = [item for item in releases
               if item["tag_name"] == tag or release_version(item) == version]
    if any(not item["draft"] for item in matches):
        raise ValueError(f"Version {display_version(version)} is already published; it cannot be replaced")
    if len(matches) > 1:
        raise ValueError("Multiple drafts reserve this version; resolve them on GitHub first")
    if matches:
        draft = matches[0]
        if draft["tag_name"] != tag or draft["prerelease"] or draft.get("immutable", False):
            raise ValueError("The existing draft does not match the expected full-release tag")
        return draft
    return None


def minimum_build_number(releases):
    # Metadata on drafts as well as published releases recovers the production
    # counter when building on another Mac or after losing local build state.
    numbers = [int(match.group(1)) for item in releases
               for match in re.finditer(BUILD_MARKER, item.get("body") or "")]
    return max(numbers, default=0)


def run(*arguments, capture=True, env=None):
    result = subprocess.run(arguments, cwd=ROOT, check=True, text=True, env=env,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def read_releases(repository):
    pages = json.loads(run("gh", "api", "--paginate", "--slurp", f"repos/{repository}/releases"))
    return [release for page in pages for release in page]


def remote_tag_object(tag):
    value = run("git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}")
    return value.split()[0] if value else ""


def require_clean_checkout():
    if run("git", "status", "--porcelain"):
        raise ValueError("Commit or stash changes and resolve untracked files before releasing")
    branch = run("git", "branch", "--show-current")
    if not branch:
        raise ValueError("Release from a named branch, not a detached HEAD")
    return branch, run("git", "rev-parse", "HEAD")


def prepare_release(bump):
    branch, commit = require_clean_checkout()
    run("gh", "auth", "status", capture=False)
    repository = run("gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner")
    releases = read_releases(repository)
    previous_version, previous_release = latest_published(releases)
    version = increment_version(previous_version, bump)
    tag = "v" + ".".join(map(str, version))
    draft = replacement_draft(releases, version, tag)
    tag_object = remote_tag_object(tag)
    local_tag = run("git", "tag", "--list", tag)
    if not draft and (tag_object or local_tag):
        raise ValueError(f"Tag {tag} already exists without a matching draft; resolve it before releasing")
    print(f"Preparing Major Tom {display_version(version)} ({tag})", flush=True)
    if draft:
        print("The existing draft will be replaced after the new candidate passes verification.", flush=True)

    run("make", "test", capture=False)
    environment = os.environ.copy()
    environment["MAJOR_TOM_MINIMUM_BUILD_NUMBER"] = str(minimum_build_number(releases))
    run("Scripts/notarize-app.sh", tag, capture=False, env=environment)
    if require_clean_checkout() != (branch, commit):
        raise ValueError("The checkout changed while building; the existing draft has been retained")

    directory = ROOT / "Build/Release"
    with (directory / "Major Tom.app/Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info["CFBundleShortVersionString"] != tag[1:] or info["MTBuildChannel"] != "production":
        raise ValueError("The packaged app does not match this production release")
    build = int(info["CFBundleVersion"])
    archive = directory / f"MajorTom-{tag}-macos.zip"
    checksum = archive.with_suffix(archive.suffix + ".sha256")
    if not archive.is_file() or not checksum.is_file():
        raise ValueError("The release archive or checksum is missing")
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    if checksum.read_text().strip() != f"{digest.hexdigest()}  {archive.name}":
        raise ValueError("The release archive does not match its checksum")
    if build <= minimum_build_number(releases) or info.get("MTBuildCommit") != commit:
        raise ValueError("The packaged build number or source commit does not match this candidate")
    # GitHub must know this commit before it can generate its release notes.
    # A rejected branch push also leaves the previous draft untouched.
    run("git", "push", "origin", f"{commit}:refs/heads/{branch}", capture=False)
    # Generate notes before touching the old draft; network or build failures
    # up to this point leave it available for testing.
    notes = json.loads(run("gh", "api", f"repos/{repository}/releases/generate-notes",
                           "-f", f"tag_name={tag}", "-f", f"target_commitish={commit}",
                           "-f", f"previous_tag_name={previous_release['tag_name']}"))["body"]
    notes += f"\n\n<!-- major-tom-build: {build} -->\n"
    notes_path = directory / "release-notes.md"
    notes_path.write_text(notes)

    fresh = read_releases(repository)
    if latest_published(fresh)[0] != previous_version:
        raise ValueError("A public release changed while building; run the command again")
    if replacement_draft(fresh, version, tag) != draft or remote_tag_object(tag) != tag_object:
        raise ValueError("The draft or tag changed while building; it has not been replaced")
    if draft:
        run("gh", "release", "delete", tag, "--yes", "--repo", repository, capture=False)
    run("git", "tag", "--force", "--annotate", tag, commit,
        "--message", f"Major Tom {display_version(version)}", capture=False)
    # Only the tag observed above may be replaced, including when it did not
    # exist. A concurrent tag update fails instead of overwriting another build.
    run("git", "push", f"--force-with-lease=refs/tags/{tag}:{tag_object}",
        "origin", f"refs/tags/{tag}", capture=False)
    run("gh", "release", "create", tag, str(archive), str(checksum), "--repo", repository,
        "--title", f"Major Tom {display_version(version)}", "--notes-file", str(notes_path),
        "--draft", "--verify-tag", capture=False)
    print(f"Draft {display_version(version)}, build {build}, is ready to test and publish.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bump", choices=("major", "minor", "patch"))
    arguments = parser.parse_args()
    directory = state_directory()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Serialize candidates from different local checkouts, which share counters.
    with (directory / "release.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        prepare_release(arguments.bump)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"error: {error}")
