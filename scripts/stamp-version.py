#!/usr/bin/env python3

import plistlib
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: stamp-version.py PLIST RELEASE COMMIT", file=sys.stderr)
        return 2

    plist_path = Path(sys.argv[1])
    release, commit = sys.argv[2:]
    with plist_path.open("rb") as source:
        info = plistlib.load(source)
    if not isinstance(info, dict):
        raise ValueError("Info.plist must contain a dictionary")

    info["GenieReleaseVersion"] = release
    info["GenieGitCommit"] = commit
    if release:
        info["CFBundleShortVersionString"] = release

    with plist_path.open("wb") as target:
        plistlib.dump(info, target, fmt=plistlib.FMT_XML, sort_keys=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
