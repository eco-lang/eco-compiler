#!/usr/bin/env python3
"""Report the constructor census (plans/constructor-representation-levels.md, unit M0).

Joins the compiler's class table (written to the path in ECO_CTOR_CENSUS when the program is
compiled) with the runtime's counts (written to the path in ECO_CTOR_CENSUS_OUT when it exits).

    ctor-census.py TABLE.tsv COUNTS.tsv [COUNTS.tsv ...] [--top N] [--by payload|tagged]

Prints the allocations, SSA constructions and promotions per level (the §1.2 table), the top N
classes of each level, and with `--by payload` the split of each level by payload class. With
`--by tagged` it prints the split by the F1 tagged-word form of each constructor
(plans/constructor-representation-followups.md F1.0: `bare`, an `alloc-*` reason, `excluded-*`, or `-`
for a type with one constructor) and the share of all allocations that `bare` constructors make, the
measure of gate F1-D. Several counts files (one per run) are summed.
Id 0 (unattributed: kernel-built objects, the out-of-line allocation path) is reported apart.
"""
import argparse
import collections
import sys


def read_tsv(path):
    with open(path, encoding="utf-8") as f:
        lines = [l.rstrip("\n").split("\t") for l in f if l.strip()]
    return lines[0], lines[1:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("table")
    ap.add_argument("counts", nargs="+")
    ap.add_argument("--top", type=int, default=8)
    ap.add_argument("--by", choices=["payload", "tagged"], default=None)
    ap.add_argument("--s2", action="store_true",
                    help="print the S2-D projection: promotions of one-constructor 2-3-field classes x 8 bytes")
    args = ap.parse_args()

    _, trows = read_tsv(args.table)
    classes = {int(r[0]): {"level": r[1], "home": r[2], "type": r[3], "ctor": r[4], "fields": int(r[5]), "payload": r[6],
                           "tagged": r[7] if len(r) > 7 else "-"} for r in trows}
    counts = {}
    for path in args.counts:
        _, crows = read_tsv(path)
        for r in crows:
            prev = counts.get(int(r[0]), (0, 0, 0))
            counts[int(r[0])] = tuple(p + int(v) for p, v in zip(prev, r[1:4]))

    by_level = collections.defaultdict(lambda: [0, 0, 0])
    by_payload = collections.defaultdict(lambda: [0, 0, 0])
    by_tagged = collections.defaultdict(lambda: [0, 0, 0])
    per_class = []
    unknown = [0, 0, 0]
    for cid, (a, s, p) in counts.items():
        cls = classes.get(cid)
        if cls is None:
            for i, v in enumerate((a, s, p)):
                unknown[i] += v
            continue
        lv = by_level[cls["level"]]
        lp = by_payload[(cls["level"], cls["payload"])]
        lt = by_tagged[cls["tagged"]]
        for i, v in enumerate((a, s, p)):
            lv[i] += v
            lp[i] += v
            lt[i] += v
        per_class.append((cls, a, s, p))

    tot = [sum(v[i] for v in by_level.values()) for i in range(3)]

    def pct(x, t):
        return f"{100.0 * x / t:5.1f}" if t else "  -  "

    def m(x):
        return f"{x / 1e6:9.2f}M"

    print(f"{'level':<10}{'allocated':>11} {'%':>5}{'ssa':>11} {'%':>5}{'promoted':>11} {'%':>5}")
    for level in sorted(by_level):
        a, s, p = by_level[level]
        print(f"{level:<10}{m(a)} {pct(a, tot[0])}{m(s)} {pct(s, tot[1])}{m(p)} {pct(p, tot[2])}")
    print(f"{'total':<10}{m(tot[0])}      {m(tot[1])}      {m(tot[2])}")
    print(f"{'unattrib.':<10}{m(unknown[0])}      {m(unknown[1])}      {m(unknown[2])}  (id 0 or unknown id)")

    if args.by == "payload":
        print()
        print(f"{'level':<6}{'payload':<12}{'allocated':>11}{'ssa':>11}{'promoted':>11}")
        for (level, payload) in sorted(by_payload):
            a, s, p = by_payload[(level, payload)]
            print(f"{level:<6}{payload:<12}{m(a)}{m(s)}{m(p)}")

    if args.by == "tagged":
        print()
        print(f"{'tagged':<26}{'allocated':>11} {'%':>5}{'ssa':>11}{'promoted':>11}")
        for form in sorted(by_tagged, key=lambda f: -by_tagged[f][0]):
            a, s, p = by_tagged[form]
            print(f"{form:<26}{m(a)} {pct(a, tot[0])}{m(s)}{m(p)}")
        bare = by_tagged.get("bare", [0, 0, 0])[0]
        print(f"\nF1-D: bare allocations {m(bare)} of {m(tot[0])} attributed custom allocations = {pct(bare, tot[0]).strip()} %"
              f" (gate: at least 5 %)")

    if args.s2:
        elig = [(c, p) for (c, a, s, p) in per_class
                if c["level"] == "2" and c["fields"] in (2, 3) and not c["payload"].endswith("+kv")]
        prom = sum(p for _, p in elig)
        print(f"\nS2-D: eligible classes {len(elig)}, promotions {prom/1e6:.2f}M, projected saving {prom*8/2**20:.1f} MiB of promoted bytes")

    for level in sorted(by_level):
        rows = sorted((c for c in per_class if c[0]["level"] == level), key=lambda c: -c[1])[: args.top]
        print(f"\nlevel {level}: top {len(rows)} by allocations")
        for cls, a, s, p in rows:
            print(f"  {cls['ctor']:<28}{cls['home']}.{cls['type']:<28}{cls['payload']:<8}{m(a)}{m(s)}{m(p)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
