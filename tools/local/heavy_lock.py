#!/usr/bin/env python3
"""重い検証（swift test / swift build / 壊し方）を、この Mac で同時に1件までにする。

使い方: python3 tools/local/heavy_lock.py [--wait 秒] -- コマンド...

ロックは worktree やクローンをまたいで共通の
~/Library/Caches/genie-in-messages/heavy.lock（mkdir で取る）。
GENIE_HEAVY_LOCK_DIR で場所を変えられる。持ち主の pid が死んでいれば古いロックとして外す。
--wait（既定 0 = すぐ失敗）のあいだ待ち、取れなければ終了コード 75 で終わる。
"""

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time

BUSY_EXIT = 75


def lock_path():
    custom = os.environ.get("GENIE_HEAVY_LOCK_DIR")
    if custom:
        return custom
    base = os.path.expanduser("~/Library/Caches")
    if not os.path.isdir(base):
        base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "genie-in-messages", "heavy.lock")


def read_owner(path):
    try:
        with open(os.path.join(path, "owner")) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def try_acquire(path, label):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        os.mkdir(path)
    except FileExistsError:
        owner = read_owner(path)
        pid = int(owner.split()[0]) if owner[:1].isdigit() else 0
        if pid and not pid_alive(pid):
            shutil.rmtree(path, ignore_errors=True)
            print("heavy-lock: 古いロックを外した（pid %d は終了済み）" % pid, file=sys.stderr)
            return try_acquire(path, label)
        if not owner:
            # 作成直後で owner がまだ無い可能性。次の回で判断する。
            return False, "(書き込み中)"
        return False, owner
    with open(os.path.join(path, "owner"), "w") as handle:
        handle.write("%d %s %s %s\n" % (os.getpid(), time.strftime("%Y-%m-%dT%H:%M:%S%z"), os.getcwd(), label))
    return True, ""


def acquire(label, wait=None):
    """ロックを取る。取れなければ BUSY_EXIT で終わる。取ったロックのパスを返す。"""
    if wait is None:
        wait = float(os.environ.get("GENIE_HEAVY_LOCK_WAIT", "0"))
    path = lock_path()
    deadline = time.monotonic() + max(0.0, wait)
    announced = False
    while True:
        ok, owner = try_acquire(path, label)
        if ok:
            return path
        if time.monotonic() >= deadline:
            print("heavy-lock: ほかの重い検証が実行中のため開始しない: %s" % owner, file=sys.stderr)
            print("heavy-lock: ロック %s 。終わるのを待つか --wait 秒 を付ける。" % path, file=sys.stderr)
            sys.exit(BUSY_EXIT)
        if not announced:
            print("heavy-lock: 待機中（実行中: %s）" % owner, file=sys.stderr, flush=True)
            announced = True
        time.sleep(2)


def release(path):
    shutil.rmtree(path, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wait", type=float, default=float(os.environ.get("GENIE_HEAVY_LOCK_WAIT", "0")))
    parser.add_argument("--label", default="")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("コマンドがありません")
    path = acquire(args.label or " ".join(command), args.wait)

    # シグナルでも必ずロックを外す。子は watchdog が自分のグループごと止める。
    child = None

    def forward(signum, _frame):
        if child is not None and child.poll() is None:
            child.send_signal(signum)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, forward)
    try:
        child = subprocess.Popen(command)
        while True:
            try:
                code = child.wait()
                break
            except InterruptedError:
                continue
    finally:
        release(path)
    sys.exit(code if code >= 0 else 128 - code)


if __name__ == "__main__":
    main()
