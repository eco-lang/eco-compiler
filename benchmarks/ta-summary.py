#!/usr/bin/env python3
"""Medians per arm for the threaded-gc-07b tenure-ageing experiment.

Usage: ta-summary.py DIR ARM [ARM ...]
  Each ARM names runs DIR/ARM-r1, -r2, -r3 (.time = GNU time -v, .stdout =
  the stats banner). Prints one row per arm with the median of each column:
  wall s, GC s (Total GC/Alloc), minor GC s, pause p50/p99/p99.9/max ms
  (phase-timer builds only), promoted MiB, old-gen peak MB, max RSS GB,
  majors, late minors, collector CPU s, ageing marked / zapped (M objects),
  zap s. Standard library only.
"""

import os
import re
import statistics
import sys


def grab(pat, text, conv=float, group=1):
    m = re.search(pat, text, re.M)
    return conv(m.group(group)) if m else None


def wall(t):
    m = re.search(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): (\S+)", t)
    if not m:
        return None
    s = 0.0
    for p in m.group(1).split(":"):
        s = s * 60 + float(p)
    return s


def run(d, tag):
    t = open(os.path.join(d, tag + ".time")).read()
    o = open(os.path.join(d, tag + ".stdout"), errors="replace").read()
    r = {
        "wall": wall(t),
        "rss": grab(r"Maximum resident set size \(kbytes\): (\d+)", t) / 1e6,
        "gc": grab(r"Total GC/Alloc time:\s+([\d.]+) s", o),
        "minor": grab(r"Minor GC \(incl\. promotion alloc\):\s+([\d.]+) s", o),
        "prom": grab(r"totals: promoted \d+ \((\d+) MiB\)", o),
        "peak": grab(r"Old-gen in-use peak:\s+([\d.]+) MB", o),
        "majors": grab(r"Major GC cycles:\s+(\d+)", o, int),
        "late": grab(r"late minors (\d+)", o, int) or 0,
        "ccpu": grab(r"collector: busy [\d.]+ s over epochs [\d.]+ s \(utilization [\d.]+; per job p50 [\d.]+ p99 [\d.]+ max [\d.]+\), CPU ([\d.]+) s", o) or 0.0,
        "marked": (grab(r"marked (\d+) objects", o) or 0) / 1e6,
        "zapped": (grab(r"(?:zapped|zap spans) (\d+)", o) or 0) / 1e6,
        "zap_s": grab(r"(?:zapped \d+ objects|zap spans \d+) \([\d.]+ MB, ([\d.]+) s in pauses\)", o) or 0.0,
    }
    m = re.search(r"all pauses\s+n=\d+\s+total=[\d.]+ s\s+p50=([\d.]+) ms\s+p90=[\d.]+ ms\s+p99=([\d.]+) ms\s+p99\.9=([\d.]+) ms\s+max=([\d.]+) ms", o)
    if m:
        r.update(p50=float(m.group(1)), p99=float(m.group(2)), p999=float(m.group(3)), pmax=float(m.group(4)))
    return r


def med(rows, k):
    v = [x[k] for x in rows if x.get(k) is not None]
    return statistics.median(v) if v else None


def f(v, fmt="{:.1f}"):
    return "-" if v is None else fmt.format(v)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    d = argv[1]
    print("| arm | wall s | GC s | minor s | pause p50/p99/p99.9/max ms | promoted MiB | peak MB | RSS GB "
          "| majors | late | coll CPU s | marked M | zapped M | zap s |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for arm in argv[2:]:
        rows = []
        for r in (1, 2, 3):
            try:
                rows.append(run(d, f"{arm}-r{r}"))
            except FileNotFoundError:
                pass
        if not rows:
            print(f"| {arm} | missing |")
            continue
        pause = "/".join(f(med(rows, k), "{:.2f}" if k == "p50" else "{:.1f}") for k in ("p50", "p99", "p999", "pmax"))
        print(f"| {arm} (n={len(rows)}) | {f(med(rows, 'wall'), '{:.2f}')} | {f(med(rows, 'gc'), '{:.2f}')} | "
              f"{f(med(rows, 'minor'), '{:.2f}')} | {pause} | {f(med(rows, 'prom'), '{:.0f}')} | "
              f"{f(med(rows, 'peak'), '{:.0f}')} | {f(med(rows, 'rss'), '{:.2f}')} | {f(med(rows, 'majors'), '{:.0f}')} | "
              f"{f(med(rows, 'late'), '{:.0f}')} | {f(med(rows, 'ccpu'))} | {f(med(rows, 'marked'), '{:.1f}')} | "
              f"{f(med(rows, 'zapped'), '{:.1f}')} | {f(med(rows, 'zap_s'), '{:.3f}')} |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
