#!/usr/bin/env python3
"""Summarise a GC event log written under ECO_GC_EVENT_LOG=<path>.

threaded-gc-00 (plans/threaded-gc-00-measure-and-fix.md Step 9). Standard
library only. Reads the tab-separated log (rows of kind minor / major / pause)
and prints:

  (a) per-phase totals and shares of the summed minor pause, with the
      unaccounted residual (should be < 2 %);
  (b) percentiles of the minor pause and of each phase per minor;
  (c) per-external-scanner totals and max slots;
  (d) the 20 worst pauses with their phase breakdown;
  (e) Pearson r of the minor pause against promoted / survived /
      lazy_sweep_bytes / stack_slots;
  (f) per-object copy cost and per-promotion allocator cost.

Usage: gc-event-log-summary.py <log.tsv> [--json]
"""

import bisect
import csv
import json
import math
import sys

PHASES = [
    "stack_walk_ns",
    "roots_longlived_jit_ns",
    "roots_stackmap_ns",
    "roots_ranges_ns",
    "roots_external_ns",
    "drain_tospace_ns",
    "drain_promoted_ns",
    "tail_ns",
    "large_body_sweep_ns",
]


def num(v):
    if v is None or v == "-" or v == "":
        return None
    try:
        return int(v)
    except ValueError:
        return None


def percentile(sorted_vals, q):
    if not sorted_vals:
        return 0
    rank = max(1, min(len(sorted_vals), math.ceil(q * len(sorted_vals))))
    return sorted_vals[rank - 1]


def pearson(xs, ys):
    n = len(xs)
    if n < 2:
        return float("nan")
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx == 0 or syy == 0:
        return float("nan")
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    return sxy / math.sqrt(sxx * syy)


def load(path):
    with open(path, newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        rows = list(reader)
        return reader.fieldnames or [], rows


def summarise(path):
    fields, rows = load(path)
    minors = [r for r in rows if r["kind"] == "minor"]
    majors = [r for r in rows if r["kind"] == "major"]
    pauses = [r for r in rows if r["kind"] == "pause"]
    ext_names = sorted({f[4:-3] for f in fields if f.startswith("ext:") and f.endswith("_ns")})

    out = {"file": path, "minors": len(minors), "majors": len(majors), "pauses": len(pauses)}
    warnings = []

    pause_sum = sum(num(r["pause_ns"]) or 0 for r in minors)
    out["minor_pause_total_ns"] = pause_sum

    # (a) phase totals and shares
    phase_tot = {p: sum(num(r[p]) or 0 for r in minors) for p in PHASES}
    accounted = sum(phase_tot.values())
    residual = pause_sum - accounted
    out["phases"] = {
        p: {"total_ns": v, "share": (v / pause_sum if pause_sum else 0.0)}
        for p, v in phase_tot.items()
    }
    out["unaccounted_ns"] = residual
    out["unaccounted_share"] = residual / pause_sum if pause_sum else 0.0
    if pause_sum and abs(residual) / pause_sum > 0.02:
        warnings.append("unaccounted residual %.2f%% > 2%% (a phase is missing)"
                        % (100.0 * residual / pause_sum))

    # (b) percentiles
    def pct_block(vals):
        s = sorted(vals)
        return {q: percentile(s, v) for q, v in
                (("p50", 0.5), ("p90", 0.9), ("p99", 0.99), ("p999", 0.999), ("max", 1.0))}

    out["minor_pause_pct_ns"] = pct_block([num(r["pause_ns"]) or 0 for r in minors])
    out["phase_pct_ns"] = {p: pct_block([num(r[p]) or 0 for r in minors]) for p in PHASES}
    out["all_pause_pct_ns"] = pct_block([num(r["pause_ns"]) or 0 for r in pauses])

    # (c) scanners
    scanners = {}
    for name in ext_names + ["late"]:
        ns_col, sl_col = "ext:%s_ns" % name, "ext:%s_slots" % name
        if ns_col not in fields:
            continue
        ns = [num(r[ns_col]) or 0 for r in minors]
        sl = [num(r[sl_col]) or 0 for r in minors]
        scanners[name] = {"total_ns": sum(ns), "max_ns": max(ns) if ns else 0,
                          "total_slots": sum(sl), "max_slots": max(sl) if sl else 0}
        if name == "late" and sum(sl):
            warnings.append("scanners registered after the log opened are lumped as 'late'")
    out["scanners"] = scanners

    # (d) 20 worst pauses (pause rows), joined to the minor row that starts it
    # A pause's minor row starts a few ns after the pause itself (separate
    # clock reads), so join on the first minor starting inside the pause.
    minor_starts = sorted((num(r["start_ns"]) or 0, i) for i, r in enumerate(minors))
    starts_only = [t for t, _ in minor_starts]

    def minor_in(p):
        a = num(p["start_ns"]) or 0
        b = a + (num(p["pause_ns"]) or 0)
        k = bisect.bisect_left(starts_only, a)
        if k < len(starts_only) and starts_only[k] <= b:
            return minors[minor_starts[k][1]]
        return None

    worst = sorted(pauses, key=lambda r: num(r["pause_ns"]) or 0, reverse=True)[:20]
    out["worst_pauses"] = []
    for p in worst:
        m = minor_in(p)
        entry = {"start_s": (num(p["start_ns"]) or 0) / 1e9,
                 "pause_ms": (num(p["pause_ns"]) or 0) / 1e6,
                 "kind": p.get("major_reason", "-")}
        if m:
            entry.update({ph: (num(m[ph]) or 0) / 1e6 for ph in PHASES})
            entry["promoted"] = num(m["promoted"])
            entry["lazy_sweep_bytes"] = num(m["lazy_sweep_bytes"])
        out["worst_pauses"].append(entry)

    # (e) correlations
    y = [num(r["pause_ns"]) or 0 for r in minors]
    out["pearson_r"] = {
        c: pearson([num(r[c]) or 0 for r in minors], y)
        for c in ("promoted", "survived", "lazy_sweep_bytes", "stack_slots")
    }

    # (f) per-object costs
    copied = sum((num(r["survived"]) or 0) + (num(r["promoted"]) or 0) for r in minors)
    promoted = sum(num(r["promoted"]) or 0 for r in minors)
    drains = phase_tot["drain_tospace_ns"] + phase_tot["drain_promoted_ns"]
    out["ns_per_copied_object_in_drain"] = drains / copied if copied else 0.0
    promo_est = sum(num(r["promo_alloc_est_ns"]) or 0 for r in minors)
    out["promo_alloc_est_ns_per_promotion"] = promo_est / promoted if promoted else 0.0
    out["lazy_sweep_est_ns_total"] = sum(num(r["lazy_sweep_est_ns"]) or 0 for r in minors)
    out["lazy_sweep_bytes_total"] = sum(num(r["lazy_sweep_bytes"]) or 0 for r in minors)
    out["frames_walked_mean"] = (sum(num(r["frames_walked"]) or 0 for r in minors) / len(minors)
                                 if minors else 0.0)
    out["frames_walked_max"] = max((num(r["frames_walked"]) or 0 for r in minors), default=0)
    out["drain_rounds_max"] = max((num(r["drain_rounds"]) or 0 for r in minors), default=0)
    out["warnings"] = warnings
    return out


def print_text(s):
    ms = lambda ns: "%.3f ms" % (ns / 1e6)
    print("GC event log: %s" % s["file"])
    print("  rows: %d minor, %d major, %d pause" % (s["minors"], s["majors"], s["pauses"]))
    tot = s["minor_pause_total_ns"]
    print("\n(a) minor pause %.3f s by phase:" % (tot / 1e9))
    for p, v in s["phases"].items():
        print("  %-24s %10.3f s  %6.2f%%" % (p, v["total_ns"] / 1e9, 100 * v["share"]))
    print("  %-24s %10.3f s  %6.2f%%" % ("unaccounted", s["unaccounted_ns"] / 1e9,
                                         100 * s["unaccounted_share"]))
    print("\n(b) percentiles per minor:")
    b = s["minor_pause_pct_ns"]
    print("  %-24s p50 %s  p90 %s  p99 %s  p99.9 %s  max %s" %
          ("minor pause", ms(b["p50"]), ms(b["p90"]), ms(b["p99"]), ms(b["p999"]), ms(b["max"])))
    for p, b in s["phase_pct_ns"].items():
        print("  %-24s p50 %s  p99 %s  max %s" % (p, ms(b["p50"]), ms(b["p99"]), ms(b["max"])))
    b = s["all_pause_pct_ns"]
    print("  %-24s p50 %s  p99 %s  max %s" % ("ALL pauses", ms(b["p50"]), ms(b["p99"]), ms(b["max"])))
    print("\n(c) external scanners:")
    for n, v in s["scanners"].items():
        print("  %-18s total %s  max %s  slots %d  max slots %d" %
              (n, ms(v["total_ns"]), ms(v["max_ns"]), v["total_slots"], v["max_slots"]))
    print("\n(d) worst pauses:")
    for w in s["worst_pauses"]:
        extra = ""
        if "drain_promoted_ns" in w:
            extra = "  drain to-space %.1f  drain promoted %.1f  stack %.1f  promoted %s  sweepB %s" % (
                w["drain_tospace_ns"], w["drain_promoted_ns"], w["stack_walk_ns"],
                w["promoted"], w["lazy_sweep_bytes"])
        print("  at %8.2f s  %9.3f ms  %-12s%s" % (w["start_s"], w["pause_ms"], w["kind"], extra))
    print("\n(e) Pearson r of minor pause vs:")
    for c, r in s["pearson_r"].items():
        print("  %-18s %.3f" % (c, r))
    print("\n(f) costs:")
    print("  drain ns per copied object:        %.1f" % s["ns_per_copied_object_in_drain"])
    print("  promotion allocator ns/promotion:  %.1f (sampled estimate, clock overhead removed)" %
          s["promo_alloc_est_ns_per_promotion"])
    print("  in-pause lazy sweep:               %.3f s est., %.3f GB" %
          (s["lazy_sweep_est_ns_total"] / 1e9, s["lazy_sweep_bytes_total"] / 1e9))
    print("  stack frames walked: mean %.1f, max %d; drain rounds max %d" %
          (s["frames_walked_mean"], s["frames_walked_max"], s["drain_rounds_max"]))
    for w in s["warnings"]:
        print("WARNING: " + w)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    s = summarise(argv[1])
    if "--json" in argv[2:]:
        json.dump(s, sys.stdout, indent=2, default=str)
        print()
    else:
        print_text(s)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
