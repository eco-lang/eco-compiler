#!/usr/bin/env python3
"""Fail on a GC shadow-root push whose count grows with the input
(plans/kernel-root-stack-bounded-rooting.md step 9).

A `pushStackRootRange(...)` or `ecoRoot1Push(...)` inside the body of a `for` /
`while` / `do` loop pushes one record per iteration. Unless the same loop body
also pops (`restoreStackRangePoint` / `ecoRootRangeRestore` /
`ecoRoot1Restore`), the shadow stack grows with the loop count and a long enough
input overflows it (the RootStack*Test E2E pins). Root a whole buffer with ONE
record (`Elm::alloc::RootedSlots` / `RootedElems`, or one all-ones range over a
presized buffer) instead.

A push that is bounded for another reason may say so on its line or the line
above: `// root-bounded: <reason>`.

Usage: check-root-bounded.py [repo-root]
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..")
DIRS = ["runtime/src", "elm-kernel-cpp/src", "eco-kernel-cpp/src"]
PUSH = re.compile(r"\b(pushStackRootRange|ecoRoot1Push)\s*\(")
POP = re.compile(r"\b(restoreStackRangePoint|ecoRootRangeRestore|ecoRoot1Restore)\s*\(")
LOOP = re.compile(r"^\s*(for|while)\s*\(|^\s*do\s*\{?\s*$|\}\s*while\s*\(")
SKIP_FILES = {"RootSet.hpp", "RootSet.cpp", "RootedSlots.hpp"}


def strip_comments(line):
    return re.sub(r"//.*", "", line)


def loop_bodies(lines):
    """Yields (start, end) line ranges of loop bodies, by brace matching."""
    for i, raw in enumerate(lines):
        line = strip_comments(raw)
        if not re.match(r"^\s*(for|while)\s*\(", line) and not re.match(r"^\s*do\b", line):
            continue
        # Find the opening brace of the body (same or a following line).
        depth = 0
        j = i
        opened = False
        paren = 0
        while j < len(lines):
            seg = strip_comments(lines[j])
            for ch in seg:
                if ch == "(":
                    paren += 1
                elif ch == ")":
                    paren -= 1
                elif ch == "{" and paren == 0:
                    depth += 1
                    opened = True
                elif ch == "}" and paren == 0:
                    depth -= 1
                    if opened and depth == 0:
                        yield (i, j)
                        break
                elif ch == ";" and paren == 0 and not opened:
                    # Single-statement loop body.
                    yield (i, j)
                    depth = -1
                    break
            if (opened and depth == 0) or depth == -1:
                break
            j += 1


def main():
    problems = []
    for d in DIRS:
        for base, _, files in os.walk(os.path.join(ROOT, d)):
            for f in files:
                if not f.endswith((".cpp", ".hpp", ".h")) or f in SKIP_FILES:
                    continue
                path = os.path.join(base, f)
                with open(path, errors="replace") as fh:
                    lines = fh.read().split("\n")
                bodies = list(loop_bodies(lines))
                for k, raw in enumerate(lines):
                    if not PUSH.search(strip_comments(raw)):
                        continue
                    if "root-bounded:" in raw or (k > 0 and "root-bounded:" in lines[k - 1]):
                        continue
                    enclosing = [(s, e) for (s, e) in bodies if s <= k <= e]
                    if not enclosing:
                        continue
                    s, e = max(enclosing, key=lambda b: b[0])  # innermost
                    if any(POP.search(strip_comments(lines[m])) for m in range(s, e + 1)):
                        continue
                    problems.append(f"{os.path.relpath(path, ROOT)}:{k + 1}: {raw.strip()}")
    if problems:
        print("check-root-bounded: a GC root push inside a loop grows the shadow stack with the input:")
        for p in problems:
            print("  " + p)
        print("Root the whole buffer with one record (Elm::alloc::RootedSlots / RootedElems),")
        print("or mark a push that is bounded for another reason with `// root-bounded: <reason>`.")
        return 1
    print("check-root-bounded: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
