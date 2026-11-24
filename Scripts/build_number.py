#!/usr/bin/env python3
"""Allocate build numbers independently of Git and disposable build output."""

import argparse
import fcntl
import os
from pathlib import Path
import tempfile


def state_directory():
    override = os.environ.get("MAJOR_TOM_BUILD_STATE_DIRECTORY")
    return Path(override).expanduser() if override else (
        Path.home() / "Library/Application Support/Major Tom Builds"
    )


def next_build_number(channel, minimum=0, directory=None):
    if channel not in ("development", "production") or minimum < 0:
        raise ValueError("Invalid build channel or minimum build number")
    directory = Path(directory) if directory is not None else state_directory()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    counter = directory / f"{channel}.txt"
    with (directory / f"{channel}.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = 0
        if counter.exists():
            value = counter.read_text().strip()
            if not value.isascii() or not value.isdecimal():
                raise ValueError(f"Invalid {channel} build counter; restore it before building")
            previous = int(value)
        number = max(previous, minimum) + 1
        descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=f".{channel}-")
        try:
            with os.fdopen(descriptor, "w") as output:
                output.write(f"{number}\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, counter)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return number


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("channel", choices=("development", "production"))
    parser.add_argument("--minimum", type=int, default=0)
    arguments = parser.parse_args()
    try:
        print(next_build_number(arguments.channel, arguments.minimum))
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
