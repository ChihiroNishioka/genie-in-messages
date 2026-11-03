#!/usr/bin/env python3
"""コマンドを上限時間つきで動かす。macOS 標準の python3 (3.9) で動く。

使い方: python3 tools/local/watchdog.py --limit 秒 [--label 名前] -- コマンド...

- swift test は xctest を「別のプロセスグループ」で起こす。親が止まると xctest は
  launchd (pid 1) の子になって残る。だからプロセスグループだけでは止められない。
  （2026-11-04 に実際に xctest が 99% CPU で残った。）
- そこで子孫を 3 つの方法で数える（0.2 秒ごとに ps で調べる）:
  1. 起動したプロセスからの親子関係（ps の ppid）
  2. これまでに見えた子孫（pid と開始時刻が同じもの）。親が消えても追える
  3. watchdog の起動後に始まり、親が pid 1 で、コマンドに作業ディレクトリの
     パスを含むもの（.build/.../xctest など、見る前に親が消えた孤児）
  macOS の ps -E は他プロセスの環境変数を見せないので、環境変数の目印は使えない。
- 上限を超えたら、子孫すべてに SIGTERM、猶予のあと SIGKILL。残っていないことを
  確かめてから終了コード 124 で終わる。
- watchdog 自身が SIGINT / SIGTERM / SIGHUP を受けたときも、子孫を止めてから
  128+シグナル番号で終わる。
- 本体が終わったのに子孫が残っていたら、止めたうえで失敗にする。
- 最後に「WATCHDOG 名前: ok|fail|timeout|interrupted ...」を1行出す。
  失敗・タイムアウト・中断を成功として扱わない。
"""

import argparse
import os
import signal
import subprocess
import sys
import time

TIMEOUT_EXIT = 124
GRACE_SECONDS = 10.0
SCAN_EVERY = 0.2


def snapshot():
    """{pid: (ppid, 開始時刻, env込みのコマンド)}。"""
    out = subprocess.run(
        ["ps", "-A", "-E", "-ww", "-o", "pid=,ppid=,lstart=,command="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        universal_newlines=True,
    ).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 7)
        if len(parts) < 7:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        started = " ".join(parts[2:7])
        command = parts[7] if len(parts) > 7 else ""
        table[pid] = (ppid, started, command)
    return table


class Tracker:
    def __init__(self, root, since, cwd):
        self.root = root
        self.since = since  # time.time() の起動時刻
        self.cwd = cwd
        self.seen = {}  # pid -> 開始時刻

    def members(self):
        table = snapshot()
        found = set()
        if self.root in table:
            found.add(self.root)
        changed = True
        while changed:
            changed = False
            for pid, (ppid, _, _) in table.items():
                if ppid in found and pid not in found:
                    found.add(pid)
                    changed = True
        for pid, (ppid, started, command) in table.items():
            if ppid == 1 and self.cwd in command and started_at(started) >= self.since - 1:
                found.add(pid)
        for pid, started in list(self.seen.items()):
            if pid in table and table[pid][1] == started:
                found.add(pid)
        found.discard(os.getpid())
        for pid in found:
            if pid in table:
                self.seen[pid] = table[pid][1]
        return found


def started_at(lstart):
    try:
        return time.mktime(time.strptime(lstart, "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return 0.0


def send(pids, sig):
    for pid in pids:
        try:
            os.kill(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass


def stop_all(proc, tracker, grace):
    """子孫をすべて止める。止められなければ False。"""
    for sig, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 5.0)):
        send(tracker.members(), sig)
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            proc.poll()
            if not tracker.members():
                return True
            time.sleep(0.2)
    proc.poll()
    return not tracker.members()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=float, required=True, help="上限（秒）")
    parser.add_argument("--label", default=None)
    parser.add_argument("--grace", type=float, default=GRACE_SECONDS)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("コマンドがありません")
    label = args.label or " ".join(command)

    wall = time.time()
    started = time.monotonic()
    proc = subprocess.Popen(command, start_new_session=True)
    tracker = Tracker(proc.pid, wall, os.getcwd())
    received = []

    def on_signal(signum, _frame):
        received.append(signum)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)

    deadline = started + args.limit
    next_scan = started
    status = None
    timed_out = False
    while True:
        status = proc.poll()
        if status is not None:
            break
        if received:
            break
        now = time.monotonic()
        if now >= deadline:
            timed_out = True
            break
        if now >= next_scan:
            tracker.members()  # 親が消える前に子孫を覚えておく
            next_scan = now + SCAN_EVERY
        time.sleep(0.2)

    leftover = sorted(tracker.members())
    stopped = True
    if timed_out or received or leftover:
        stopped = stop_all(proc, tracker, args.grace)
    elapsed = time.monotonic() - started

    if received:
        result, code = "interrupted", 128 + received[0]
    elif timed_out:
        result, code = "timeout", TIMEOUT_EXIT
    elif leftover:
        result, code = "fail(子プロセスが残った pid=%s)" % leftover, 1
    elif status == 0:
        result, code = "ok", 0
    else:
        result, code = "fail", status if status and status > 0 else 1
    note = "" if stopped else " 子プロセスを止められなかった"
    print(
        "WATCHDOG %s: %s exit=%s %.1fs (上限 %ds)%s"
        % (label, result, code, elapsed, int(args.limit), note),
        file=sys.stderr,
        flush=True,
    )
    if not stopped and code == 0:
        code = 1
    sys.exit(code)


if __name__ == "__main__":
    main()
