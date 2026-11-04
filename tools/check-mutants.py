#!/usr/bin/env python3
"""Apply one mutant at a time and require its named test to fail by assertion."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MUTANTS = Path(__file__).resolve().parent / "mutants"
MANIFEST = MUTANTS / "manifest.json"
PROBES = MUTANTS / "probes.json"


def classify_build(rc):
    return "BUILD_OK" if rc == 0 else "BUILD_FAILED"


def classify_test(rc, output, test_name):
    if rc == 0:
        return "SURVIVED"
    if any(token in output for token in (
        "Fatal error:", "Exited with signal code", "Exited with unexpected signal code"
    )):
        return "CRASHED"
    if ": threw error" in output:
        return "ERRORED"
    escaped = re.escape(test_name)
    if "." in test_name:
        cls, _, method = test_name.rpartition(".")
        names = rf"(?:{escaped}|-\[(?:\w+\.)?{re.escape(cls)} {re.escape(method)}\])"
    else:
        names = escaped
    assertion_line = re.search(
        rf"^.*{names}.*(?:: XCT[^\n]* failed|: failed -).*$", output, re.MULTILINE
    )
    summary_line = re.search(
        rf"^Test Case '{names}' failed(?: \([0-9.]+ seconds\))?\.?$", output, re.MULTILINE
    )
    if assertion_line and summary_line:
        return "KILLED"
    return "RUN_FAILED"


def run(args, *, capture=False):
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=capture)


def baseline(entry):
    result = run(["swift", "test", "--filter", entry["filter"]], capture=True)
    output = result.stdout + result.stderr
    executed = re.search(r"Executed\s+(\d+)\s+tests?\b", output)
    if result.returncode == 0 and executed and int(executed.group(1)) > 0:
        return "BASELINE_OK"
    return "BASELINE_FAILED"


def exercise(entry):
    name = entry["name"]
    patch_name = entry.get("patch")
    applied = False
    if patch_name:
        patch = MUTANTS / patch_name
        result = run(["git", "apply", str(patch)], capture=True)
        if result.returncode != 0:
            print(f"APPLY_FAILED {name}", flush=True)
            return "APPLY_FAILED"
        applied = True
    try:
        built = run(["swift", "build", "--build-tests"], capture=True)
        build_status = classify_build(built.returncode)
        if build_status != "BUILD_OK":
            print(f"{build_status} {name}", flush=True)
            return build_status
        tested = run(["swift", "test", "--skip-build", "--filter", entry["filter"]], capture=True)
        outcome = classify_test(tested.returncode, tested.stdout + tested.stderr, entry["filter"])
        print(f"{outcome} {name}", flush=True)
        return outcome
    finally:
        if applied:
            restored = run(["git", "apply", "-R", str(MUTANTS / patch_name)], capture=True)
            if restored.returncode != 0:
                print(f"RESTORE_FAILED {name}", flush=True)
                raise RuntimeError("RESTORE_FAILED")


def run_entries(entries, probes=False):
    failures = []
    for entry in entries:
        name = entry["name"]
        base = baseline(entry)
        if probes and name == "P-BASELINE":
            outcome = base
        else:
            if base != "BASELINE_OK":
                print(f"BASELINE_FAILED {name}", flush=True)
                failures.append(name)
                continue
            outcome = exercise(entry)
        if probes:
            if outcome == entry["expect"]:
                print(f"PROBE_OK {name}", flush=True)
            else:
                print(f"PROBE_FAILED {name}: expected {entry['expect']}, got {outcome}", flush=True)
                failures.append(name)
        elif outcome != "KILLED":
            failures.append(name)
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probes", action="store_true")
    parser.add_argument("--classify-test", nargs=2, metavar=("RC", "TEST"))
    args = parser.parse_args()
    if args.classify_test:
        rc, test = args.classify_test
        print(classify_test(int(rc), sys.stdin.read(), test))
        return 0
    entries = json.loads((PROBES if args.probes else MANIFEST).read_text(encoding="utf-8"))
    failures = run_entries(entries, probes=args.probes)
    if failures:
        print("failed: " + ", ".join(failures), flush=True)
        return 1
    print("all probes passed" if args.probes else "all mutants killed", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        if str(error) == "RESTORE_FAILED":
            raise SystemExit(2)
        raise
