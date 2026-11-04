#!/usr/bin/env python3
"""Fail on a GC external root scanner registered without a name (DEAD-19, plans/kernel-lib-bug-fixes.md).

Every `addExternalRootScanner(` call outside RootSet must pass a name as its second argument: a string literal,
or a static-lifetime `const char*` such as Registry's `name_`. The name labels the scanner in
`RootSet::getExternalRootScannerNames()` and the GC event log. An unnamed scanner is labelled
`unnamed@<symbol or address>` by RootSet.cpp, which in a static binary is usually just an address.

Usage: check-scanner-names.py [repo-root] [-v]   (-v also lists the named calls)
Exits 1 when any call lacks a name, 0 otherwise.
"""
import os, re, sys
root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..")
DIRS = ["runtime/src", "elm-kernel-cpp/src", "eco-kernel-cpp/src", "system-kernel-cpp/src"]
SKIP = {"RootSet.hpp", "RootSet.cpp"}
CALL = re.compile(r"\baddExternalRootScanner\s*\(")

def strip(text):
    # Drop // and /* */ comments, keep string literals (and newlines, for line numbers).
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1]); i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i); j = n if j < 0 else j; i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2); j = n if j < 0 else j + 2
            out.append("\n" * text.count("\n", i, j)); i = j
        else:
            out.append(c); i += 1
    return "".join(out)

def last_arg(src, open_idx):
    depth, i, start = 0, open_idx, open_idx + 1
    args = []
    while i < len(src):
        c = src[i]
        if c == '"':
            j = i + 1
            while j < len(src) and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            i = j + 1; continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append(src[start:i]); return args
        elif c == "," and depth == 1:
            args.append(src[start:i]); start = i + 1
        i += 1
    return args

bad, good = [], []
for d in DIRS:
    for dp, _, fs in os.walk(os.path.join(root, d)):
        for f in fs:
            if f in SKIP or not f.endswith((".cpp", ".hpp", ".h", ".cc")):
                continue
            p = os.path.join(dp, f)
            src = strip(open(p, encoding="utf-8", errors="replace").read())
            for m in CALL.finditer(src):
                line = src.count("\n", 0, m.start()) + 1
                args = last_arg(src, m.end() - 1)
                last = args[-1].strip() if args else ""
                rel = os.path.relpath(p, root)
                named = len(args) >= 2 and last not in ("nullptr", "NULL", "0", '"unnamed"', '""')
                if named:
                    good.append(f"{rel}:{line} {last}")
                else:
                    bad.append(f"{rel}:{line} (last argument: {last.splitlines()[0] if last else '<none>'} ...)")
if "-v" in sys.argv[2:]:
    for g in good:
        print("named   ", g)
for b in bad:
    print("UNNAMED ", b)
sys.exit(1 if bad else 0)
