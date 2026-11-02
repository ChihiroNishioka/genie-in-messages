#!/usr/bin/env python3
"""壊し方を1つずつ当て、対応するテストが落ちることを確かめる。

テストが通ったら、その壊し方は生き残っている。CI は失敗にする。
終わったらパッチを戻す。使い方は LESSONS.md。
"""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path(__file__).resolve().parent / "mutants" / "manifest.json"


def run(args):
    return subprocess.run(args, cwd=ROOT, text=True)


def main():
    entries = json.loads(MANIFEST.read_text())
    survived = []
    for entry in entries:
        patch = ROOT / "tools" / "mutants" / entry["patch"]
        name = entry["name"]
        applied = run(["git", "apply", str(patch)])
        if applied.returncode != 0:
            print(f"APPLY_FAILED {name}", flush=True)
            survived.append(name)
            continue
        try:
            tested = run(["swift", "test", "--filter", entry["filter"]])
            if tested.returncode == 0:
                print(f"SURVIVED {name}", flush=True)
                survived.append(name)
            else:
                print(f"KILLED {name}", flush=True)
        finally:
            reversed_ok = run(["git", "apply", "-R", str(patch)])
            if reversed_ok.returncode != 0:
                print(f"RESTORE_FAILED {name}", flush=True)
                sys.exit(2)
    if survived:
        print("survived: " + ", ".join(survived), flush=True)
        sys.exit(1)
    print("all mutants killed", flush=True)


if __name__ == "__main__":
    main()
