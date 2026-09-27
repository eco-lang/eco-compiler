#!/usr/bin/env python3
"""Compare the GC counters of two (or more) self-compile runs by class.

threaded-gc-06 (plans/threaded-gc-06-parallel-minor.md P§3.15, E1): with
gc_minor_threads > 1 the OBJECT class must be identical across worker counts;
the LAYOUT and DECISION classes may differ (old-gen placement is schedule-
dependent) and are printed, not gated. At N = 1 against the pre-phase-6 binary
every class must match.

Usage:
  tg6-compare.py REF.stdout OTHER.stdout [...] [--log REF.tsv OTHER.tsv ...] [--all]

  --all   also require the decision class to match (E0: N = 1 vs the reference)

Exit status: 0 when every gated class matches, 1 otherwise.
Standard library only.
"""

import csv
import re
import sys

# Banner keys by class. Anything not listed is "other" (timing, layout detail).
OBJECT_KEYS = [
    "Objects allocated", "Objects survived", "Objects promoted", "Minor GC cycles",
    "Nursery grow events", "Maximum nursery size", "Bytes allocated",
]
DECISION_KEYS = [
    "Major GC cycles", "Mark-sweeps completed", "Garbage-frac triggers",
    "Live-budget triggers", "Headroom triggers", "Occupancy triggers",
    "Global-pressure triggers", "Alloc-fail triggers",
]
# Sections whose rows are object-class (per-kind retention).
OBJECT_SECTIONS = ["Retention by Object Kind", "Promoted Custom by Field Count"]
DECISION_SECTIONS = ["Major GC Event Log"]

KV = re.compile(r"^\s*([A-Za-z][A-Za-z0-9 ()/%.-]*?):\s+(.*\S)\s*$")


def banner(path):
    kv, sections, cur = {}, {}, None
    started = False
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        if "=== GC Statistics ===" in line:
            started = True
            continue
        if not started:
            continue
        if line and not line.startswith(" ") and line.endswith(":"):
            cur = line.split(" (")[0].rstrip(":")
            sections[cur] = []
            continue
        if cur is not None and line.strip():
            sections[cur].append(line)
        m = KV.match(line)
        if m:
            kv.setdefault(m.group(1).strip(), m.group(2))
    return kv, sections


def strip_timing(rows):
    # Major GC Event Log rows: drop the leading time/duration columns (the first
    # five numeric fields: at, total, mark, sweep, roots); keep reason and sizes.
    out = []
    for r in rows:
        f = r.split()
        if len(f) > 5 and re.match(r"^[0-9.]+$", f[0]):
            out.append(" ".join(f[5:6] + f[6:]))
        else:
            out.append(r.strip())
    return out


def minor_rows(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            if r.get("kind") == "minor":
                rows.append((r["survived"], r["promoted"], r["survived_bytes"], r["promoted_bytes"]))
    return rows


def main(argv):
    args = argv[1:]
    gate_all = "--all" in args
    args = [a for a in args if a != "--all"]
    logs = []
    if "--log" in args:
        i = args.index("--log")
        logs = args[i + 1:]
        args = args[:i]
    if len(args) < 2:
        print(__doc__)
        return 2
    ref_kv, ref_sec = banner(args[0])
    ok = True
    for other in args[1:]:
        kv, sec = banner(other)
        print("== %s vs %s" % (args[0], other))
        for cls, keys, gated in (("object", OBJECT_KEYS, True), ("decision", DECISION_KEYS, gate_all)):
            for k in keys:
                a, b = ref_kv.get(k), kv.get(k)
                if a != b:
                    print("  %s%s  %-28s %s -> %s" % (cls, "" if gated else " (not gated)", k, a, b))
                    ok = ok and not gated
        for s in OBJECT_SECTIONS:
            if ref_sec.get(s) != sec.get(s):
                print("  object  section '%s' differs" % s)
                ok = False
        for s in DECISION_SECTIONS:
            a, b = strip_timing(ref_sec.get(s, [])), strip_timing(sec.get(s, []))
            if a != b:
                print("  decision%s section '%s' differs (%d vs %d rows)" %
                      ("" if gate_all else " (not gated)", s, len(a), len(b)))
                ok = ok and not gate_all
    if logs:
        ref = minor_rows(logs[0])
        for other in logs[1:]:
            rows = minor_rows(other)
            diffs = [i for i, (x, y) in enumerate(zip(ref, rows)) if x != y]
            if len(ref) != len(rows) or diffs:
                print("  object  per-minor log %s: %d vs %d rows, first diff at minor %s" %
                      (other, len(ref), len(rows), diffs[0] if diffs else "-"))
                ok = False
            else:
                print("  per-minor log %s: %d minors identical" % (other, len(rows)))
    print("RESULT: %s" % ("MATCH" if ok else "DIFFER"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
