#!/usr/bin/env python3
"""Fail closed when the selected test suite did not actually execute."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def check(kind, path, minimum):
    if minimum < 1:
        raise ValueError("Minimum test count must be positive")
    if kind == "swift":
        text = Path(path).read_text()
        matches = re.findall(r"Test run with (\d+) tests? in .*? passed", text)
        if not matches or "✘" in text:
            raise ValueError("No successful Swift Testing summary")
        passed = int(matches[-1])
    else:
        data = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(path), "--compact"], text=True)
        summary = json.loads(data)
        if summary.get("failedTests", 0) or summary.get("expectedFailures", 0):
            raise ValueError("Test failures were reported")
        passed = summary.get("passedTests", 0)
    if passed < minimum:
        raise ValueError(f"Expected at least {minimum} passing tests, received {passed}")
    print(f"Verified {passed} passing tests (minimum {minimum})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=["swift", "xcode"])
    parser.add_argument("path", type=Path)
    parser.add_argument("--minimum", required=True, type=int)
    args = parser.parse_args()
    try:
        check(args.kind, args.path, args.minimum)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
