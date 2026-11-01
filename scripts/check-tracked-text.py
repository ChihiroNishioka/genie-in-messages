#!/usr/bin/env python3
"""追跡されているテキストに、秘密や個人の連絡先・Notion ID が無いか見る。

出力は「パス: 種類」だけ。一致した値は出さない。
example.com と、0000 が並ぶ仕様上の架空の番号は許す。
"""

from __future__ import annotations

import re
import subprocess
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_SUFFIXES = {
    ".png",
    ".icns",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".pdf",
    ".zip",
    ".gz",
}

EMAIL = re.compile(r"(?i)\b[a-z0-9._%+\-]+@([a-z0-9.\-]+\.[a-z]{2,})\b")
ALLOWED_EMAIL_DOMAINS = {"example.com", "example.org", "example.net"}
FILE_SUFFIXES = {"png", "jpg", "jpeg", "gif", "svg", "icns", "py", "sh", "md", "json", "txt", "swift"}
UUID = re.compile(
    r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"
)
TOKEN = re.compile(
    r"(?i)("
    r"\b(?:sk|rk)-[A-Za-z0-9]{20,}\b"
    r"|\bgh[pousr]_[A-Za-z0-9]{20,}\b"
    r"|\bgithub_pat_[A-Za-z0-9_]{20,}\b"
    r"|\bxox[baprs]-[A-Za-z0-9-]{10,}\b"
    r"|\bntn_[A-Za-z0-9]{20,}\b"
    r"|\bAKIA[0-9A-Z]{16}\b"
    r"|Bearer\s+[A-Za-z0-9\-._~+/]{24,}"
    r")"
)
PHONE = re.compile(
    r"(?<![\w/])(?:\+\d{1,3}[\s().-]*)?(?:\(?\d{2,4}\)?[\s().-]*){2,4}\d{3,4}(?![\w/])"
)
ADDRESS = re.compile(
    r"(?:〒\s*\d{3}-?\d{4}"
    r"|\b\d{1,5}\s+[A-Za-z0-9.'-]+\s+(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd)\b)"
)


def tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    paths: list[Path] = []
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        path = ROOT / raw.decode()
        if path.suffix.lower() in SKIP_SUFFIXES or not path.is_file():
            continue
        paths.append(path)
    return paths


def notion_id_is_personal(value: str) -> bool:
    digits = re.sub(r"[^0-9a-f]", "", value.lower())
    return len(set(digits)) > 4


def phone_is_personal(value: str) -> bool:
    folded = unicodedata.normalize("NFKC", value)
    if not re.search(r"[+\s().-]", folded):
        return False
    digits = re.sub(r"\D", "", folded)
    if not 10 <= len(digits) <= 15:
        return False
    if "0000" in digits:
        return False
    return True


def findings_in(text: str) -> set[str]:
    found: set[str] = set()
    for match in EMAIL.finditer(text):
        domain = match.group(1).lower()
        suffix = domain.rsplit(".", 1)[-1]
        if suffix in FILE_SUFFIXES:
            continue
        if domain in ALLOWED_EMAIL_DOMAINS or domain.endswith(".example"):
            continue
        found.add("email")
    if any(notion_id_is_personal(item.group(0)) for item in UUID.finditer(text)):
        found.add("notion-id")
    if TOKEN.search(text):
        found.add("token")
    if any(phone_is_personal(item.group(0)) for item in PHONE.finditer(text)):
        found.add("phone")
    if ADDRESS.search(text):
        found.add("address")
    return found


def main() -> int:
    problems: list[str] = []
    for path in tracked_files():
        data = path.read_bytes()
        if b"\0" in data:
            continue
        text = data.decode("utf-8", errors="replace")
        relative = path.relative_to(ROOT).as_posix()
        for kind in sorted(findings_in(text)):
            problems.append(f"{relative}: {kind}")
    if problems:
        print("\n".join(problems))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
