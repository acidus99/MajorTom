#!/usr/bin/env python3
"""Concise development/test progress, with complete output in a private log."""

import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def run_stage(label, arguments, log):
    print(f"{label}...", flush=True)
    log.write("$ " + " ".join(map(str, arguments)) + "\n")
    log.flush()
    start = log.tell()
    result = subprocess.run(arguments, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    log.flush()
    with Path(log.name).open() as source:
        source.seek(start)
        output = source.read()
    if result.returncode:
        print(f"{label} failed.", file=sys.stderr)
        diagnostics = [line for line in output.splitlines() if re.search(
            r"error:|failed|Traceback|AssertionError|^FAIL:|^ERROR:", line)]
        print("\n".join(diagnostics[-20:] or output.splitlines()[-30:]), file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, arguments)
    return output


def test_summary(python_output, swift_output):
    python_match = re.search(r"Ran ([0-9]+) tests? in", python_output)
    suites = re.findall(r"Test Suite 'All tests' passed[^\n]*\n([^\n]*)", swift_output)
    if not python_match or not suites:
        raise ValueError("The test runners did not report completed test suites; inspect the log")
    total = 0
    skipped = 0
    for suite in suites:
        executed = re.search(r"Executed ([0-9]+) tests?", suite)
        failures = re.search(r"([0-9]+) failures?", suite)
        if not executed or not failures or int(failures.group(1)):
            raise ValueError("The test summary is incomplete or reports failures; inspect the log")
        total += int(executed.group(1))
        skip = re.search(r"([0-9]+) tests? skipped", suite)
        skipped += int(skip.group(1)) if skip else 0
    if total == 0:
        raise ValueError("No app tests ran; inspect the log")
    summary = f"Tests passed: {python_match.group(1)} release-script tests, {total - skipped} app tests"
    return summary + (f" ({skipped} skipped)." if skipped else ".")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("dev", "test"))
    arguments = parser.parse_args()
    directory = Path("/tmp/MajorTom")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(mode="w", prefix=f"{arguments.action}-", suffix=".log",
                                     dir=directory, delete=False) as log:
        try:
            python_output = run_stage("Testing release scripts", [sys.executable, "-B", "-m", "unittest",
                "discover", "-s", "Tests/BuildScripts", "-p", "test_*.py"], log)
            swift_output = run_stage("Building and running app tests", ["Scripts/run-tests.sh"], log)
            print(test_summary(python_output, swift_output), flush=True)
            if arguments.action == "dev":
                run_stage("Building development app", ["Scripts/build-app.sh"], log)
                app = Path("Build/Development/Major Tom.app")
                with (ROOT / app / "Contents/Info.plist").open("rb") as source:
                    info = plistlib.load(source)
                print(f"Ready: Development Build {info['CFBundleVersion']}")
                print(f"App: {app}")
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            print(f"error: {error}", file=sys.stderr)
            print(f"Log: {log.name}", file=sys.stderr)
            return 1
        print(f"Log: {log.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
