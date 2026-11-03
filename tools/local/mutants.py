#!/usr/bin/env python3
"""壊し方（変異テスト）を、変更に関係するものだけ、上限時間つきで動かす。

使い方:
  python3 tools/local/mutants.py                 # origin/main からの変更に関係するもの
  python3 tools/local/mutants.py --base REF      # REF からの変更に関係するもの
  python3 tools/local/mutants.py --only GREEN24  # 名前で選ぶ（複数可）
  python3 tools/local/mutants.py --all           # 全部（明示したときだけ）
  python3 tools/local/mutants.py --list          # 選ばれるものを表示するだけ

- 表は tools/mutants/manifest.json（どこでも動く）と platform-manifest.json
  （linux-* / macos-*）。run-mutants.sh / check-mutants.py と同じ表を使う。
- 「関係する」とは、変更されたファイルが次のどれかに当たること:
  パッチが書き換えるファイル、パッチ自身、対応するテストを定義するファイル、
  XCTestCase を含まない共有のテスト補助（Harness.swift など。全件に関係する）。
- 全体の上限は既定 1800 秒（30 分）。1件ごとの swift test は watchdog と同じ方法で
  子孫まで止める。上限・中断・失敗のどれでも、書き換えたファイルを元のバイト列に戻し、
  git status と内容のハッシュが開始前と同じことを確かめる。
- 結果: KILLED（テストが失敗で落とした）だけが合格。SURVIVED、TIMEOUT、
  RUN DID NOT TEST（落ちたがテストの失敗ではない＝クラッシュ等）、APPLY FAILED は不合格。
- macOS で linux-* を動かした結果は「macOS で実行」と書く。Linux の検証ではない。
- 重い検証のロック（heavy_lock.py）を取る。
"""

import argparse
import hashlib
import json
import os
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import heavy_lock  # noqa: E402
import watchdog  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
MUTANTS = os.path.join(ROOT, "tools", "mutants")
TOTAL_LIMIT = 1800.0
RUN_LIMIT = 900.0
TOOL_FILES = {
    "tools/local/mutants.py",
    "tools/check-mutants.py",
    "tools/run-mutants.sh",
    "tools/mutants/manifest.json",
    "tools/mutants/platform-manifest.json",
}


class Interrupted(Exception):
    pass


def git(*args, check=True):
    out = subprocess.run(
        ["git"] + list(args), cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True
    )
    if check and out.returncode != 0:
        raise SystemExit("git %s に失敗: %s" % (" ".join(args), out.stderr.strip()))
    return out.stdout


def load_entries():
    entries = []
    with open(os.path.join(MUTANTS, "manifest.json")) as handle:
        for item in json.load(handle):
            entries.append(dict(item, platform="any"))
    with open(os.path.join(MUTANTS, "platform-manifest.json")) as handle:
        entries.extend(json.load(handle))
    tests = test_definitions()
    for entry in entries:
        entry["targets"] = patch_targets(entry["patch"])
        method = entry["filter"].split(".")[-1]
        entry["test_file"] = tests.get(method, "")
    return entries


def patch_targets(name):
    targets = []
    with open(os.path.join(MUTANTS, name)) as handle:
        for line in handle:
            if line.startswith("+++ b/"):
                targets.append(line[6:].strip())
    return targets


def test_definitions():
    """テストメソッド名 → 定義しているファイル。"""
    found = {}
    for path in tracked_tests():
        with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
            for match in re.finditer(r"func (test\w+)\s*\(", handle.read()):
                found.setdefault(match.group(1), path)
    return found


def tracked_tests():
    return [p for p in git("ls-files", "Tests").splitlines() if p.endswith(".swift")]


def is_shared_helper(path):
    if not (path.startswith("Tests/") and path.endswith(".swift")):
        return False
    full = os.path.join(ROOT, path)
    if not os.path.exists(full):
        return False
    with open(full, encoding="utf-8") as handle:
        return "XCTestCase" not in handle.read()


def changed_files(base):
    names = set(git("diff", "--name-only", "%s...HEAD" % base).splitlines())
    names |= set(git("diff", "--name-only", "HEAD").splitlines())
    names |= set(git("ls-files", "--others", "--exclude-standard").splitlines())
    return sorted(n for n in names if n)


def select(entries, changed):
    reasons = {}
    changed_set = set(changed)
    shared = [p for p in changed if is_shared_helper(p)]
    for entry in entries:
        why = []
        hit = changed_set.intersection(entry["targets"])
        if hit:
            why.append("書き換え先 " + ", ".join(sorted(hit)))
        if "tools/mutants/" + entry["patch"] in changed_set:
            why.append("パッチ")
        if entry["test_file"] and entry["test_file"] in changed_set:
            why.append("テスト " + entry["test_file"])
        if shared:
            why.append("共有のテスト補助 " + ", ".join(shared))
        if why:
            reasons[entry["name"]] = "; ".join(why)
    return reasons


def runnable_here(entry):
    system = platform.system()
    if entry["platform"] == "macos":
        return system == "Darwin", "macOS 専用（GenieMenuBar のテスト）"
    return True, ""


def platform_note(entry):
    if entry["platform"] == "linux" and platform.system() == "Darwin":
        return "（macOS で実行。Linux の検証ではない）"
    return ""


def snapshot(paths):
    saved = {}
    for path in paths:
        full = os.path.join(ROOT, path)
        if os.path.exists(full):
            with open(full, "rb") as handle:
                saved[path] = handle.read()
        else:
            saved[path] = None
    return saved


def restore(saved):
    for path, data in saved.items():
        full = os.path.join(ROOT, path)
        if data is None:
            if os.path.exists(full):
                os.remove(full)
        else:
            with open(full, "rb") as handle:
                if handle.read() == data:
                    continue
            with open(full, "wb") as handle:
                handle.write(data)


def digest(saved):
    h = hashlib.sha256()
    for path in sorted(saved):
        full = os.path.join(ROOT, path)
        h.update(path.encode())
        if os.path.exists(full):
            with open(full, "rb") as handle:
                h.update(handle.read())
    return h.hexdigest()


def run_one(entry, limit, log_path):
    """swift test --filter を上限つきで動かす。(status, timed_out, log)"""
    with open(log_path, "w") as log:
        proc = subprocess.Popen(
            ["swift", "test", "--filter", entry["filter"]],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        tracker = watchdog.Tracker(proc.pid, time.time(), ROOT)
        deadline = time.monotonic() + limit
        timed_out = False
        try:
            while proc.poll() is None:
                if time.monotonic() >= deadline:
                    timed_out = True
                    break
                tracker.members()
                time.sleep(0.2)
        finally:
            if proc.poll() is None or tracker.members():
                if not watchdog.stop_all(proc, tracker, 10.0):
                    print("  子プロセスを止められなかった", file=sys.stderr)
    with open(log_path, errors="replace") as handle:
        text = handle.read()
    return proc.returncode, timed_out, text


def classify(status, timed_out, text):
    if timed_out:
        return "TIMEOUT"
    if status == 0:
        return "SURVIVED"
    if re.search(r"Test Case '.*' failed", text) or re.search(r"error: -\[.*\] : ", text):
        return "KILLED"
    return "RUN DID NOT TEST"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--all", action="store_true", help="関係の有無によらず全部（明示したときだけ）")
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--limit", type=float, default=TOTAL_LIMIT, help="全体の上限（秒）")
    parser.add_argument("--run-limit", type=float, default=RUN_LIMIT, help="1件の上限（秒）")
    parser.add_argument("--log-dir", default=None)
    args = parser.parse_args()

    entries = load_entries()
    by_name = {e["name"]: e for e in entries}
    if args.only:
        unknown = [n for n in args.only if n not in by_name]
        if unknown:
            raise SystemExit("知らない名前: " + ", ".join(unknown))
        reasons = {n: "指定" for n in args.only}
    elif args.all:
        reasons = {e["name"]: "--all" for e in entries}
    else:
        changed = changed_files(args.base)
        reasons = select(entries, changed)
        print("基準 %s からの変更 %d 件" % (args.base, len(changed)))
        tool_changes = sorted(TOOL_FILES.intersection(changed))
        if tool_changes:
            print("注意: 壊し方の道具が変わった（%s）。全件の確認は --all で明示して動かす。" % ", ".join(tool_changes))

    selected = [e for e in entries if e["name"] in reasons]
    print("選ばれた壊し方 %d / %d 件" % (len(selected), len(entries)))
    for entry in selected:
        ok, why_not = runnable_here(entry)
        mark = "" if ok else "  [この OS では未実施: %s]" % why_not
        print("  %s  ← %s%s" % (entry["name"], reasons[entry["name"]], mark))
    if args.list:
        return 0
    if not selected:
        print("MUTANTS: 対象なし（0 件実行。合格ではなく未実施）")
        return 0

    head = git("rev-parse", "HEAD").strip()
    status_before = git("status", "--porcelain")
    every_target = sorted({t for e in selected for t in e["targets"]})
    saved = snapshot(every_target)
    digest_before = digest(saved)
    log_dir = args.log_dir or tempfile.mkdtemp(prefix="genie-mutants-")
    os.makedirs(log_dir, exist_ok=True)

    def on_signal(signum, _frame):
        raise Interrupted(signum)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)

    lock = heavy_lock.acquire("mutants %s" % head[:7])
    started = time.monotonic()
    deadline = started + args.limit
    results = []
    exit_code = 0
    try:
        for entry in selected:
            ok, why_not = runnable_here(entry)
            if not ok:
                results.append((entry["name"], "NOT RUN", 0.0, why_not))
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                results.append((entry["name"], "NOT RUN", 0.0, "全体の上限に達した"))
                continue
            t0 = time.monotonic()
            patch = os.path.join(MUTANTS, entry["patch"])
            applied = subprocess.run(["git", "apply", patch], cwd=ROOT)
            if applied.returncode != 0:
                restore(saved)
                results.append((entry["name"], "APPLY FAILED", time.monotonic() - t0, ""))
                continue
            try:
                log_path = os.path.join(log_dir, entry["name"] + ".log")
                status, timed_out, text = run_one(entry, min(args.run_limit, remaining), log_path)
            finally:
                restore(saved)
            outcome = classify(status, timed_out, text)
            results.append((entry["name"], outcome, time.monotonic() - t0, platform_note(entry)))
            print("%s %s %.1fs%s" % (outcome, entry["name"], time.monotonic() - t0, platform_note(entry)), flush=True)
    except Interrupted as stop:
        print("中断（シグナル %d）。戻してから終わる。" % stop.args[0], file=sys.stderr)
        exit_code = 128 + stop.args[0]
    finally:
        restore(saved)
        heavy_lock.release(lock)
        restored = digest(snapshot(every_target)) == digest_before and git("status", "--porcelain") == status_before

    elapsed = time.monotonic() - started
    over = elapsed >= args.limit or any(r[3] == "全体の上限に達した" for r in results)
    print("")
    print("MUTANTS HEAD %s  経過 %.1fs（上限 %ds）  ログ %s" % (head[:7], elapsed, int(args.limit), log_dir))
    for name, outcome, seconds, note in results:
        print("  %-30s %-16s %6.1fs %s" % (name, outcome, seconds, note))
    print("  書き換えたファイルの復元: %s" % ("OK（内容と git status が開始前と同じ）" if restored else "失敗"))
    if not restored:
        return 3
    if exit_code:
        return exit_code
    if over:
        return watchdog.TIMEOUT_EXIT
    if any(r[1] not in ("KILLED", "NOT RUN") for r in results):
        return 1
    if any(r[1] == "NOT RUN" for r in results):
        print("  未実施があるので、全件合格ではない。")
        return 1 if all(r[1] == "NOT RUN" for r in results) else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
