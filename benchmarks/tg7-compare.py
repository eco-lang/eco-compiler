#!/usr/bin/env python3
"""Compare self-compile runs of the region nursery by determinism class.

threaded-gc-07 (plans/threaded-gc-07-concurrent-tenuring.md P§3.18, E1 / E2).

  E1: legacy nursery (REF) vs region mode (OTHER): the OBJECT class must be
      identical, with tenured counts shifted one minor: region row m+1
      `promoted` (= the tenured count its merge applied) == legacy row m
      `promoted`; survived counts row by row; run totals after the exit merge.
  E2: region mode 1 (REF) vs mode 2 (OTHER) with --exact: every class
      identical (object, region, layout, decision), timing columns excluded.

Usage:
  tg7-compare.py e1 LEGACY.stdout REGION.stdout --log LEGACY.tsv REGION.tsv
  tg7-compare.py e2 MODE1.stdout MODE2.stdout --log MODE1.tsv MODE2.tsv [--exact]

Banners (the stats stdout) give run totals; event logs (ECO_GC_EVENT_LOG,
phase-timer builds) give the per-minor rows. Exit status 0 = match.
Standard library only.
"""

import csv
import re
import sys

OBJECT_KEYS = [
    "Objects allocated", "Objects survived", "Objects promoted", "Minor GC cycles",
    "Nursery grow events", "Maximum nursery size", "Bytes allocated",
]
DECISION_KEYS = [
    "Major GC cycles", "Mark-sweeps completed", "Garbage-frac triggers",
    "Live-budget triggers", "Headroom triggers", "Occupancy triggers",
    "Global-pressure triggers", "Alloc-fail triggers",
]
KV = re.compile(r"^\s*([A-Za-z][A-Za-z0-9 ()/%.-]*?):\s+(.*\S)\s*$")

# Region columns by class (P§3.18).
REGION_OBJECT_COLS = ["rg_tenured", "rg_tenured_bytes", "rg_ylos_promoted", "rg_ylos_freed",
                      "rg_lb_promoted"]
REGION_REGION_COLS = ["rg_starts", "rg_heal_recorded", "rg_resolved", "rg_heal_slots",
                      "rg_fill_obj_bytes", "rg_bld_bytes"]
REGION_LAYOUT_COLS = ["rg_grant_blocks", "rg_grant_cells", "rg_grant_used"]


def banner(path):
    kv, started = {}, False
    for line in open(path, errors="replace"):
        if "=== GC Statistics ===" in line:
            started = True
            continue
        if not started:
            continue
        m = KV.match(line.rstrip("\n"))
        if m:
            kv.setdefault(m.group(1).strip(), m.group(2))
    return kv


def rows(path):
    out = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            if r.get("kind") == "minor":
                out.append(r)
    return out


def num(r, k):
    v = r.get(k, "")
    return int(float(v)) if v not in ("", "-", None) else 0


def main(argv):
    if len(argv) < 4 or argv[1] not in ("e1", "e2"):
        print(__doc__)
        return 2
    mode, ref_out, oth_out = argv[1], argv[2], argv[3]
    logs = []
    exact = "--exact" in argv
    if "--log" in argv:
        i = argv.index("--log")
        logs = argv[i + 1:i + 3]
    ok = True

    a, b = banner(ref_out), banner(oth_out)
    print("== run totals (object class)")
    for k in OBJECT_KEYS:
        same = a.get(k) == b.get(k)
        ok &= same
        print(f"  {'OK ' if same else 'DIFF'} {k}: {a.get(k)} | {b.get(k)}")
    print("== run totals (decision class: " + ("gated" if exact else "printed") + ")")
    for k in DECISION_KEYS:
        same = a.get(k) == b.get(k)
        if exact:
            ok &= same
        print(f"  {'OK ' if same else 'diff'} {k}: {a.get(k)} | {b.get(k)}")

    if logs:
        ra, rb = rows(logs[0]), rows(logs[1])
        print(f"== per-minor rows: {len(ra)} | {len(rb)}")
        if len(ra) != len(rb):
            ok = False
            print("  DIFF row counts")
        n = min(len(ra), len(rb))
        bad = 0
        for m in range(n):
            if num(ra[m], "survived") != num(rb[m], "survived") or \
               num(ra[m], "survived_bytes") != num(rb[m], "survived_bytes"):
                bad += 1
                if bad <= 5:
                    print(f"  DIFF survived at minor {m}: {num(ra[m], 'survived')} | {num(rb[m], 'survived')}")
        if mode == "e1":
            # region row m+1 `promoted` == legacy row m `promoted` (P§3.18).
            for m in range(n - 1):
                if num(ra[m], "promoted") != num(rb[m + 1], "promoted") or \
                   num(ra[m], "promoted_bytes") != num(rb[m + 1], "promoted_bytes"):
                    bad += 1
                    if bad <= 5:
                        print(f"  DIFF promoted legacy[{m}] {num(ra[m], 'promoted')} vs "
                              f"region[{m + 1}] {num(rb[m + 1], 'promoted')}")
        else:
            cols = REGION_OBJECT_COLS + REGION_REGION_COLS + (REGION_LAYOUT_COLS if exact else [])
            for m in range(n):
                for c in cols + ["promoted", "promoted_bytes"]:
                    if num(ra[m], c) != num(rb[m], c):
                        bad += 1
                        if bad <= 5:
                            print(f"  DIFF {c} at minor {m}: {num(ra[m], c)} | {num(rb[m], c)}")
        print(f"  per-minor object{'/region/layout' if exact else '/region'} mismatches: {bad}")
        ok &= bad == 0
        if exact:
            ma = [r for r in csv.DictReader(open(logs[0]), delimiter="\t") if r.get("kind") == "major"]
            mb = [r for r in csv.DictReader(open(logs[1]), delimiter="\t") if r.get("kind") == "major"]
            same = len(ma) == len(mb)
            print(f"  majors: {len(ma)} | {len(mb)} {'OK' if same else 'DIFF'}")
            ok &= same
    print("RESULT", "MATCH" if ok else "DIFFER")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
