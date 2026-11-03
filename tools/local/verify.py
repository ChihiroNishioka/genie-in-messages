#!/usr/bin/env python3
"""普段の検証を、この Mac で上限時間つきで動かす。

使い方: python3 tools/local/verify.py [--log-dir DIR]

順に:
  0. .github/workflows に自動起動（push / pull_request / schedule など）が無いことを確かめる
  1. 秘密の検査       python3 scripts/check-tracked-text.py       上限 120 秒
  2. テスト           swift test                                 上限 900 秒（15 分）
  3. ビルド           swift build --product GenieMenuBar          上限 900 秒（15 分）

- 重い検証のロック（heavy_lock.py）を取ってから始める。ほかの検証中なら待たずに 75 で終わる。
- 各段は watchdog と同じ方法で子孫まで止める。上限を超えたら 124。
- 1 段でも失敗・タイムアウトなら、残りは「未実施」と書き、0 以外で終わる。
- 壊し方（変異テスト）はここでは動かさない。tools/local/mutants.py を別に動かす。
- Linux の検証はしない。Mac で通っても Linux の結果ではない。
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import heavy_lock  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
WATCHDOG = os.path.join(HERE, "watchdog.py")
AUTO_TRIGGERS = ("push", "pull_request", "pull_request_target", "schedule", "workflow_run", "merge_group", "release")

STEPS = [
    ("secret-scan", 120, ["python3", "scripts/check-tracked-text.py"]),
    ("swift-test", 900, ["swift", "test"]),
    ("build-GenieMenuBar", 900, ["swift", "build", "--product", "GenieMenuBar"]),
]


def automatic_triggers():
    """workflow ごとの on: に並ぶ自動起動のキー。"""
    found = []
    folder = os.path.join(ROOT, ".github", "workflows")
    if not os.path.isdir(folder):
        return found
    for name in sorted(os.listdir(folder)):
        if not name.endswith((".yml", ".yaml")):
            continue
        lines = open(os.path.join(folder, name), encoding="utf-8").read().splitlines()
        inside = False
        for line in lines:
            if re.match(r'^["\']?on["\']?\s*:', line):
                inside = True
                inline = line.split(":", 1)[1]
                for key in AUTO_TRIGGERS:
                    if re.search(r"\b%s\b" % key, inline):
                        found.append("%s: %s" % (name, key))
                continue
            if inside:
                if line and not line[0].isspace() and not line.startswith("#"):
                    inside = False
                    continue
                match = re.match(r"^\s+-?\s*([A-Za-z_]+)\s*:?", line)
                if match and match.group(1) in AUTO_TRIGGERS:
                    found.append("%s: %s" % (name, match.group(1)))
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log-dir", default=None)
    args = parser.parse_args()
    log_dir = args.log_dir or tempfile.mkdtemp(prefix="genie-verify-")
    os.makedirs(log_dir, exist_ok=True)
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, stdout=subprocess.PIPE, universal_newlines=True
    ).stdout.strip()
    dirty = subprocess.run(
        ["git", "status", "--porcelain"], cwd=ROOT, stdout=subprocess.PIPE, universal_newlines=True
    ).stdout.strip()

    results = []
    triggers = automatic_triggers()
    results.append(("workflow-triggers", "ok" if not triggers else "fail", 0.0, "; ".join(triggers)))

    lock = heavy_lock.acquire("verify %s" % head[:7])
    failed = bool(triggers)
    code = 1 if triggers else 0
    try:
        for label, limit, command in STEPS:
            if failed:
                results.append((label, "未実施", 0.0, "前の段が失敗"))
                continue
            log_path = os.path.join(log_dir, label + ".log")
            started = time.monotonic()
            with open(log_path, "w") as log:
                status = subprocess.call(
                    [sys.executable, WATCHDOG, "--limit", str(limit), "--label", label, "--"] + command,
                    cwd=ROOT,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                )
            elapsed = time.monotonic() - started
            if status == 0:
                outcome = "ok"
            elif status == 124:
                outcome = "timeout"
            else:
                outcome = "fail(exit=%d)" % status
            note = summary_line(log_path, label)
            results.append((label, outcome, elapsed, note))
            print("%-20s %-14s %7.1fs  %s" % (label, outcome, elapsed, note), flush=True)
            if status != 0:
                failed = True
                code = status
    except KeyboardInterrupt:
        results.append(("(中断)", "interrupted", 0.0, ""))
        code = 130
    finally:
        heavy_lock.release(lock)

    print("")
    print("VERIFY HEAD %s%s  ログ %s" % (head, "（未コミットの変更あり）" if dirty else "", log_dir))
    for label, outcome, elapsed, note in results:
        print("  %-20s %-14s %7.1fs  %s" % (label, outcome, elapsed, note))
    print("  壊し方（変異テスト）: ここでは未実施。関係する変更なら tools/local/mutants.py")
    print("  Linux の検証: 未実施（この Mac の結果は Linux の結果ではない）")
    print("  結果: %s" % ("成功" if code == 0 else "失敗（失敗・タイムアウト・未実施を成功として扱わない）"))
    return code


def summary_line(log_path, label):
    try:
        text = open(log_path, errors="replace").read()
    except OSError:
        return ""
    if label == "swift-test":
        found = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", text)
        if found:
            total, failures = found[-1]
            return "%s tests, %s failures" % (total, failures)
    if label.startswith("build"):
        match = re.search(r"Build complete!.*", text)
        if match:
            return match.group(0).strip()
    lines = [l for l in text.splitlines() if l.strip()]
    return lines[-1][:120] if lines else ""


if __name__ == "__main__":
    sys.exit(main())
