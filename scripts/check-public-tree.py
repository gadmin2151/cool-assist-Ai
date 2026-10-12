#!/usr/bin/env python3
"""Conservative publication guard. Reports paths/rule names, never matched secrets."""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
ALLOWED_ROOTS = {"Sources", "Tests", "Resources", "scripts", "android", "desktop", "design", ".github"}
ALLOWED_TOP = {".gitignore", "Package.swift", "README.md", "RELEASE-2.0.0.md", "SECURITY.md"}
FORBIDDEN_PARTS = {".tools", "models", "vendor", "dist", "artifacts", "node_modules", ".gradle", "build", ".build", "out", "Meetings"}
FORBIDDEN_SUFFIXES = {".pem", ".p12", ".pfx", ".key", ".jks", ".keystore", ".db", ".sqlite", ".sqlite3", ".log", ".wav", ".pcm", ".m4a", ".mp4", ".apk", ".dmg", ".exe", ".deb", ".pkg"}
RULES = {
    "OpenAI credential": rb"sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{40,}",
    "GitHub credential": rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})",
    "private key material": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    "AWS access key": rb"(?:AKIA|ASIA)[0-9A-Z]{16}",
    "Slack credential": rb"xox[baprs]-[0-9A-Za-z-]{20,}",
    "personal machine path": rb"/Users/(?!Shared(?:/|\b))[a-zA-Z0-9_.-]+/",
    "private network address": rb"\b(?:192\.168\.[0-9]{1,3}\.[0-9]{1,3}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\b",
}


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="Check the entire Git index, including tracked files")
    args = parser.parse_args()
    names = git("ls-files", "-z") if args.staged else git("ls-files", "--cached", "--others", "--exclude-standard", "-z")
    paths = sorted(set(p.decode() for p in names.split(b"\0") if p))
    failures: list[tuple[str, str]] = []
    for name in paths:
        p = pathlib.PurePosixPath(name)
        if (len(p.parts) == 1 and name not in ALLOWED_TOP) or (len(p.parts) > 1 and p.parts[0] not in ALLOWED_ROOTS):
            failures.append((name, "outside publication allowlist"))
        if FORBIDDEN_PARTS.intersection(p.parts) or p.suffix.lower() in FORBIDDEN_SUFFIXES or p.name.startswith(".env") or p.name in {"local.properties", "signing.properties"}:
            failures.append((name, "private/generated file"))
        if "RELEASE-1" in p.name or p.name.startswith("AUDIT-"):
            failures.append((name, "historical machine-specific report"))
        data = git("show", ":" + name) if args.staged else (ROOT / name).read_bytes()
        if len(data) > 20 * 1024 * 1024:
            failures.append((name, "oversized file; review asset provenance"))
        if b"\0" in data:
            allowed_binary = name == "android/gradle/wrapper/gradle-wrapper.jar" or (p.suffix == ".png" and p.parts[0] in {"design", "desktop"})
            if not allowed_binary:
                failures.append((name, "unexpected binary"))
            continue
        for rule, pattern in RULES.items():
            if re.search(pattern, data):
                failures.append((name, rule))
    for name, rule in failures:
        print(f"BLOCK: {name}: {rule}")
    print(f"Checked {len(paths)} files; {len(failures)} issue(s). This guard complements manual review; it is not a guarantee of secret absence.")
    return int(bool(failures))


if __name__ == "__main__":
    sys.exit(main())
