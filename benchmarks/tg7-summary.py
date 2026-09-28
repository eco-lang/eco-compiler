#!/usr/bin/env python3
"""One row per self-compile run of threaded-gc-07's measurement arms.

Usage: tg7-summary.py DIR TAG [TAG ...]
  For each TAG reads DIR/TAG.time (GNU time -v), DIR/TAG.stdout (the stats
  banner) and, when present, DIR/TAG.tsv / TAG.events.tsv (the event log).

Columns: wall (s), max RSS (GB), all-pause p50/p99/max (ms), minor-only
max (ms), total pause (s), mutator CPU outside pauses (s), majors, old-gen
peak (MB), late tenure jobs, collector busy / CPU (s), MMU 50/100/200 ms.
Standard library only.
"""

import os
import re
import sys


def grab(pat, text, conv=float, group=1, default=None):
    m = re.search(pat, text, re.M)
    return conv(m.group(group)) if m else default


def wall(path):
    t = open(path).read()
    m = re.search(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): (\S+)", t)
    if not m:
        return None
    parts = [float(x) for x in m.group(1).split(":")]
    s = 0.0
    for p in parts:
        s = s * 60 + p
    return s


def rss(path):
    return grab(r"Maximum resident set size \(kbytes\): (\d+)", open(path).read()) / 1e6


def row(d, tag):
    out = open(os.path.join(d, tag + ".stdout"), errors="replace").read()
    r = {"tag": tag, "wall": wall(os.path.join(d, tag + ".time")), "rss": rss(os.path.join(d, tag + ".time"))}
    m = re.search(r"all pauses\s+n=(\d+)\s+total=([\d.]+) s\s+p50=([\d.]+) ms\s+p90=([\d.]+) ms\s+p99=([\d.]+) ms\s+p99.9=([\d.]+) ms\s+max=([\d.]+) ms", out)
    if m:
        r.update(ptot=float(m.group(2)), p50=float(m.group(3)), p99=float(m.group(5)), pmax=float(m.group(7)))
    r["minor_max"] = grab(r"minor-only pauses.*max=([\d.]+) ms", out)
    r["mut_out"] = grab(r"mutator CPU [\d.]+ s, of which in pauses [\d.]+ s; outside pauses ([\d.]+) s", out)
    r["majors"] = grab(r"Major GC cycles:\s+(\d+)", out, int)
    r["peak"] = grab(r"Old-gen in-use peak:\s+([\d.]+) MB", out)
    r["late"] = grab(r"late minors (\d+)", out, int, default=0)
    r["busy"] = grab(r"collector: busy ([\d.]+) s", out, default=0.0)
    r["ccpu"] = grab(r"collector: busy [\d.]+ s over epochs [\d.]+ s \(utilization [\d.]+; per job p50 [\d.]+ p99 [\d.]+ max [\d.]+\), CPU ([\d.]+) s", out, default=0.0)
    for w in (50, 100, 200):
        r[f"mmu{w}"] = grab(rf"MMU\s+{w} ms:\s+([\d.]+)%", out)
    return r


def fmt(v, f="{:.1f}"):
    return "-" if v is None else f.format(v)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    d = argv[1]
    print("| arm | wall s | RSS GB | pause p50/p99/max ms | minor max | pause total s | mutator out s | majors | peak MB | late | coll busy/CPU s | MMU 50/100/200 |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for tag in argv[2:]:
        try:
            r = row(d, tag)
        except FileNotFoundError:
            print(f"| {tag} | missing |")
            continue
        print(f"| {tag} | {fmt(r['wall'])} | {fmt(r['rss'], '{:.2f}')} | "
              f"{fmt(r.get('p50'), '{:.2f}')}/{fmt(r.get('p99'))}/{fmt(r.get('pmax'))} | "
              f"{fmt(r['minor_max'])} | {fmt(r.get('ptot'), '{:.2f}')} | {fmt(r['mut_out'])} | "
              f"{r['majors']} | {fmt(r['peak'], '{:.0f}')} | {r['late']} | "
              f"{fmt(r['busy'])}/{fmt(r['ccpu'])} | "
              f"{fmt(r['mmu50'])}/{fmt(r['mmu100'])}/{fmt(r['mmu200'])} |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
