#!/usr/bin/env python3
"""Score a heap-profile.py sweep with the decision model of
plans/gc-param-sweep/sensitivity-2026-09-28.md section 4.

Usage: gc-sweep-eval.py GROUP_DIR [--budget-ceiling 122] [--markdown]

Reads GROUP_DIR/runs_raw.tsv. The reference is every VALID run of the cells
named baseline, baseline_mid and baseline_end (9 runs at N=3): its median is
the baseline and its spread sets the noise band of each scored metric,
eps = max(2 sigma, floor). Each other cell is compared by the median of its
valid runs.

Scored (positive = improvement, in seconds of wall):
  wall gain                  baseline - cell
  pause credit               2 s per 10 % lower pause p99
  CPU credit                 1 s per 2 s less user+sys CPU
  promotion credit           1 s per 2.5 % less promoted
  RSS credit / penalty       1 s per 2 % of max RSS
A change inside its eps counts as zero. The RSS eps is widened to 2 sigma of
the garbage-fraction cells' medians (--chaos-prefix): see the comment there. Positive non-wall credit is capped
at 10 s in total.

Gates: every run valid (rc 0, no signal, reference output hash), pause max
<= 1.5 x baseline, wall <= the absolute ceiling (default 122 s).

Verdicts:
  WIN    wall gain > eps and no scored metric regresses beyond its eps
  TRADE  adjusted > eps_wall and all gates pass
  INERT  minors, majors and every scored metric within eps of baseline
         (collector counters identical to the baseline median)
  FLAT   scored metrics within eps but the collector counters moved, or
         only small improvements that do not clear the wall band
  [SWAP] suffix: a run took > 10k major page faults (the heap was paged, so
         its wall and pauses partly measure the disk)
  LOSS   everything else (including any failed gate)
Standard library only.
"""

import argparse
import statistics
import sys
from pathlib import Path

BASELINE_CELLS = ("baseline", "baseline_mid", "baseline_end")

# metric -> noise-band floor (applied when 2 sigma is smaller)
FLOORS = {
    "wall_s": 1.5,          # s (plan section 3)
    "pause_p99_ms": 1.0,    # ms
    "cpu_s": 2.0,           # s
    "promoted_MiB": 100.0,  # MiB (~0.5 % of ~20 GiB)
    "max_rss_GB": 0.1,      # GB
    "pause_max_ms": 5.0,    # ms (reported, gate only)
}


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def read_tsv(path: Path) -> list[dict]:
    with path.open() as f:
        cols = f.readline().rstrip("\n").split("\t")
        return [dict(zip(cols, line.rstrip("\n").split("\t"))) for line in f]


def med(rows, col):
    vals = [num(r.get(col)) for r in rows]
    vals = [v for v in vals if v is not None]
    return statistics.median(vals) if vals else None


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("group_dir", type=Path)
    ap.add_argument("--budget-ceiling", type=float, default=122.0)
    ap.add_argument("--chaos-prefix", default="mgf_",
                    help="cells whose RSS spread sets the RSS noise band "
                         "(default: the major_gc_garbage_fraction sweep)")
    ap.add_argument("--rss-eps", type=float, default=None,
                    help="RSS noise band in GB, for a sitting without chaos "
                         "cells (carry it over from one that had them)")
    ap.add_argument("--markdown", action="store_true",
                    help="print markdown tables instead of TSV")
    a = ap.parse_args(argv)

    raw = read_tsv(a.group_dir / "runs_raw.tsv")
    valid = lambda r: r.get("valid") in ("true", "True")
    cells: dict[str, list[dict]] = {}
    order: list[str] = []
    for r in raw:
        if r["name"] not in cells:
            order.append(r["name"])
        cells.setdefault(r["name"], []).append(r)

    ref_rows = [r for n in BASELINE_CELLS for r in cells.get(n, []) if valid(r)]
    if len(ref_rows) < 2:
        sys.exit("need at least 2 valid baseline runs")
    base, eps = {}, {}
    for col, floor in FLOORS.items():
        vals = [num(r[col]) for r in ref_rows if num(r.get(col)) is not None]
        base[col] = statistics.median(vals)
        sd = statistics.stdev(vals) if len(vals) > 1 else 0.0
        eps[col] = max(2 * sd, floor)
    for col in ("minor_gcs", "major_gcs"):
        base[col] = med(ref_rows, col)

    # The baseline repeats all follow ONE major-GC schedule, so their RSS
    # spread (~0.01 GB) says nothing about the chaotic major trigger, which
    # moves max RSS by 1-2 GB on a 1 % change in the minor schedule
    # (plans/threaded-gc-07b-tenure-ageing.md section 7). The garbage-fraction
    # cells sweep that trigger directly: 2 sigma of their per-cell medians,
    # with the baseline median, is the RSS band.
    if a.rss_eps is not None:
        eps["max_rss_GB"] = max(eps["max_rss_GB"], a.rss_eps)
        print(f"# RSS band set explicitly: eps {eps['max_rss_GB']:.2f} GB")
    chaos = [n for n in order if n.startswith(a.chaos_prefix)]
    chaos_meds = [med([r for r in cells[n] if valid(r)], "max_rss_GB") for n in chaos]
    chaos_meds = [v for v in chaos_meds if v is not None] + [base["max_rss_GB"]]
    if len(chaos_meds) >= 3:
        eps["max_rss_GB"] = max(eps["max_rss_GB"], 2 * statistics.stdev(chaos_meds))
        print(f"# RSS band from the trigger-chaos cells {', '.join(chaos)}: "
              f"medians {', '.join(f'{v:.2f}' for v in chaos_meds)} -> "
              f"eps {eps['max_rss_GB']:.2f} GB")

    print(f"# reference: {len(ref_rows)} valid runs of {', '.join(BASELINE_CELLS)}")
    for col in FLOORS:
        vals = [num(r[col]) for r in ref_rows if num(r.get(col)) is not None]
        sd = statistics.stdev(vals) if len(vals) > 1 else 0.0
        print(f"#   {col:14} median {base[col]:10.3f}  sd {sd:8.3f}  eps {eps[col]:8.3f}"
              + ("  (widened below)" if col == "max_rss_GB" else ""))
    for n in BASELINE_CELLS:
        rows = [r for r in cells.get(n, []) if valid(r)]
        if rows:
            print(f"#   drift {n:13} wall {med(rows, 'wall_s'):8.2f}  "
                  f"p99 {med(rows, 'pause_p99_ms'):7.2f}  cpu {med(rows, 'cpu_s'):8.2f}")

    def within(col, v):
        return abs(v - base[col]) <= eps[col]

    out = []
    for name in order:
        if name in BASELINE_CELLS:
            continue
        rows = cells[name]
        vrows = [r for r in rows if valid(r)]
        m = {c: med(vrows, c) for c in
             ("wall_s", "pause_p99_ms", "pause_max_ms", "cpu_s", "promoted_MiB",
              "max_rss_GB", "minor_gcs", "major_gcs", "pause_p50_ms",
              "mmu_200ms_pct", "mutator_cpu_out_s", "collector_cpu_s",
              "conc_mark_cpu_s", "oldgen_peak_MB", "late_minors", "gc_total_s")}
        row = {"name": name, "change": rows[0].get("change", ""),
               "valid": f"{len(vrows)}/{len(rows)}", **m}
        gates = []
        if len(vrows) < len(rows) or not vrows:
            gates.append("invalid-runs")
        if not vrows:
            row.update(verdict="LOSS", gates=",".join(gates), adjusted=None)
            out.append(row)
            continue
        if m["pause_max_ms"] is not None and m["pause_max_ms"] > 1.5 * base["pause_max_ms"]:
            gates.append("pause-max")
        if m["wall_s"] > a.budget_ceiling:
            gates.append("ceiling")

        d_wall = base["wall_s"] - m["wall_s"]
        wall_gain = 0.0 if abs(d_wall) <= eps["wall_s"] else d_wall

        def credit(col, rate_per_unit, pct):
            v = m[col]
            if v is None or within(col, v):
                return 0.0
            d = base[col] - v
            return rate_per_unit * (100.0 * d / base[col] if pct else d)

        pause_c = credit("pause_p99_ms", 0.2, True)     # 2 s per 10 %
        cpu_c = credit("cpu_s", 0.5, False)             # 1 s per 2 s
        promo_c = credit("promoted_MiB", 0.4, True)     # 1 s per 2.5 %
        rss_c = credit("max_rss_GB", 0.5, True)         # 1 s per 2 %
        non_wall = pause_c + cpu_c + promo_c + rss_c
        if non_wall > 10.0:
            non_wall = 10.0
        adjusted = wall_gain + non_wall

        regress = [c for c in ("pause_p99_ms", "cpu_s", "promoted_MiB", "max_rss_GB")
                   if m[c] is not None and m[c] - base[c] > eps[c]]
        if (m["wall_s"] - base["wall_s"]) > eps["wall_s"]:
            regress.append("wall_s")
        all_within = all(m[c] is not None and within(c, m[c])
                         for c in ("wall_s", "pause_p99_ms", "cpu_s",
                                   "promoted_MiB", "max_rss_GB"))
        counters_same = (m["minor_gcs"] == base["minor_gcs"]
                         and m["major_gcs"] == base["major_gcs"])

        if gates:
            verdict = "LOSS"
        elif wall_gain > 0 and not regress:
            verdict = "WIN"
        elif adjusted > eps["wall_s"]:
            verdict = "TRADE"
        elif all_within:
            verdict = "INERT" if counters_same else "FLAT"
        elif not regress:
            # Moved only in the good direction, but not by enough to clear
            # the wall band: nothing to adopt, nothing lost.
            verdict = "FLAT"
        else:
            verdict = "LOSS"
        # Swapping: a run with many major (I/O) page faults paged the heap,
        # so its wall and pauses measure the disk, not the collector.
        faults = []
        for rep in (r.get("rep") for r in rows):
            tp = a.group_dir / "variants" / name / f"r{rep}" / "time.txt"
            if tp.exists():
                for line in tp.read_text().splitlines():
                    if "Major (requiring I/O) page faults:" in line:
                        faults.append(int(line.rsplit(":", 1)[1]))
        if faults and max(faults) > 10000:
            verdict += " [SWAP]"
        row["major_faults_max"] = max(faults) if faults else None
        row.update(verdict=verdict, gates=",".join(gates), adjusted=adjusted,
                   d_wall=d_wall, pause_c=pause_c, cpu_c=cpu_c, promo_c=promo_c,
                   rss_c=rss_c, regress=",".join(regress))
        out.append(row)

    f = lambda v, d=2: "" if v is None else f"{v:.{d}f}"
    if a.markdown:
        print("\n| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB "
              "| RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |")
        print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|")
        for r in out:
            cr = ("" if r.get("adjusted") is None else
                  f"{r['pause_c']:+.1f}/{r['cpu_c']:+.1f}/{r['promo_c']:+.1f}/{r['rss_c']:+.1f}")
            note = r["verdict"] + (f" ({r['gates']})" if r["gates"] else "") + \
                (f" ↑{r['regress']}" if r.get("regress") else "")
            print(f"| `{r['name']}` | {r['valid']} | {f(r['wall_s'])} | {f(r.get('d_wall'), 1)} "
                  f"| {f(r['pause_p99_ms'], 1)} | {f(r['pause_max_ms'], 1)} | {f(r['cpu_s'], 1)} "
                  f"| {f(r['promoted_MiB'], 0)} | {f(r['max_rss_GB'], 2)} "
                  f"| {f(r['minor_gcs'], 0)} / {f(r['major_gcs'], 0)} | {cr} "
                  f"| {f(r.get('adjusted'), 1)} | {note} |")
    else:
        cols = ["name", "valid", "wall_s", "d_wall", "pause_p99_ms", "pause_max_ms",
                "cpu_s", "promoted_MiB", "max_rss_GB", "minor_gcs", "major_gcs",
                "pause_c", "cpu_c", "promo_c", "rss_c", "adjusted", "verdict",
                "gates", "regress"]
        print("\t".join(cols))
        for r in out:
            print("\t".join(f(r.get(c)) if isinstance(r.get(c), float) or r.get(c) is None
                            else str(r.get(c)) for c in cols))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
