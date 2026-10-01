#!/usr/bin/env python3
"""Summarise mem-trace.sh runs (plans/frontend-heap-release.md §8.1). Standard library only.

usage: mem-trace-summary.py [--json] PREFIX [PREFIX...]

Each PREFIX names the files mem-trace.sh wrote (<prefix>.tsv .time .stdout .stderr .meta).
Prefixes that differ only in a trailing "-r<N>" (a triple: x-r1 x-r2 x-r3) also get a median row.

Per run:
  peaks      sampled peak RSS and when; `time -v` maximum RSS; minimum MemAvailable and when;
             maximum swap used (SwapFree's drop from the first sample); major faults
  phases     FE = up to the last sample where the GC thread groups' CPU rises by > 0.2 s;
             BE = the rest; inside BE the first rise in thread count is the MLIR context and the
             second the parallel code generation. Duration, peak and mean RSS of each.
  gc reports every "[gc-report]" line of <prefix>.stderr, placed on the time axis (by the TSV's
             gc_reports column when present), with the sampled RSS just before and after it
  INVALID    `time -v` shows a signal or a non-zero exit; "[gc-stats] SIG" in stderr; the -w
             output file is missing; MemAvailable under 256 MB for more than 10 s

Also reads the pre-mem-trace Stage 9b sampler format (t_s column, all zero because bc was
absent): time is then reconstructed from the `time -v` wall clock, evenly spaced.
"""
import json
import os
import re
import statistics
import sys

GC_GROUPS = ("eco-gc", "eco-mark", "eco-cmark", "eco-tenure")
REAPER_MB = 256
REAPER_S = 10.0
GC_RISE_S = 0.2
REPORT_RE = re.compile(r"^\[gc-report\] v=1 (.*)$")


def read_text(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return None


def parse_time_v(text):
    out = {}
    if not text:
        return out
    for line in text.splitlines():
        line = line.strip()
        if ":" not in line:
            continue
        if line.startswith("Command terminated by signal"):
            out["signal"] = int(line.rsplit(" ", 1)[1])
            continue
        if line.startswith("Command exited with non-zero status"):
            out["exit_status"] = int(line.rsplit(" ", 1)[1])
            continue
        key, _, val = line.rpartition(": ")
        val = val.strip()
        if key.startswith("Maximum resident set size"):
            out["max_rss_mb"] = int(val) / 1024.0
        elif key.startswith("Major (requiring I/O) page faults"):
            out["majflt"] = int(val)
        elif key.startswith("Elapsed (wall clock) time"):
            parts = [float(p) for p in val.split(":")]
            secs = 0.0
            for p in parts:
                secs = secs * 60 + p
            out["wall_s"] = secs
        elif key == "Exit status":
            out["exit_status"] = int(val)
        elif key.startswith("User time"):
            out["user_s"] = float(val)
        elif key.startswith("System time"):
            out["sys_s"] = float(val)
    return out


def parse_meta(text):
    meta = {}
    for line in (text or "").splitlines():
        k, sep, v = line.partition("=")
        if sep:
            meta[k] = v
    return meta


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def parse_groups(field):
    """'eco:1.2 eco-gc-0:0.3' -> {'eco': 1.2, 'eco-gc': 0.3} (old format: strip -<digits>)."""
    g = {}
    for tok in (field or "").split():
        name, _, v = tok.rpartition(":")
        val = num(v)
        if not name or val is None:
            continue
        name = re.sub(r"-[0-9]+$", "", name)
        g[name] = g.get(name, 0.0) + val
    return g


def load_samples(tsv_text, wall_s):
    lines = [l for l in tsv_text.splitlines() if l.strip()]
    if not lines:
        return [], None
    header = lines[0].split("\t")
    rc = None
    rows = []
    for l in lines[1:]:
        m = re.match(r"^exit rc=(-?\d+)", l)
        if m:
            rc = int(m.group(1))
            continue
        cols = l.split("\t")
        rows.append(dict(zip(header, cols + [""] * (len(header) - len(cols)))))
    samples = []
    old = "t_ms" not in header
    for r in rows:
        if old:
            t = num(r.get("t_s"))
        else:
            t = num(r.get("t_ms"))
            t = t / 1000.0 if t is not None else None
        groups = parse_groups(r.get("group_cpu", r.get("thread_cpu_by_name", "")))
        samples.append({
            "t": t,
            "rss": num(r.get("rss_mb")),
            "hwm": num(r.get("hwm_mb")),
            "threads": num(r.get("threads")),
            "cpu": num(r.get("cpu_s")),
            "majflt": num(r.get("majflt")),
            "memavail": num(r.get("memavail_mb")),
            "swapfree": num(r.get("swapfree_mb")),
            "out": num(r.get("out_mb", r.get("eco2_mb"))),
            "ngc": num(r.get("gc_reports")),
            "gc_cpu": sum(v for k, v in groups.items() if k in GC_GROUPS),
        })
    if old and samples and all((s["t"] or 0) == 0 for s in samples):
        # bc was missing in the old sampler: spread the samples evenly over the wall time
        step = (wall_s / len(samples)) if wall_s else 1.0
        for i, s in enumerate(samples):
            s["t"] = i * step
        for s in samples:
            s["t_reconstructed"] = True
    return samples, rc


def phase_stats(samples):
    rss = [s["rss"] for s in samples if s["rss"] is not None]
    if not samples:
        return None
    return {
        "start_s": samples[0]["t"],
        "end_s": samples[-1]["t"],
        "dur_s": samples[-1]["t"] - samples[0]["t"],
        "peak_rss_mb": max(rss) if rss else None,
        "mean_rss_mb": statistics.fmean(rss) if rss else None,
    }


def summarise(prefix):
    tsv = read_text(prefix + ".tsv")
    if tsv is None:
        raise SystemExit("mem-trace-summary: cannot read %s.tsv" % prefix)
    tv = parse_time_v(read_text(prefix + ".time"))
    meta = parse_meta(read_text(prefix + ".meta"))
    stderr = read_text(prefix + ".stderr") or ""
    samples, rc = load_samples(tsv, tv.get("wall_s"))
    live = [s for s in samples if s["rss"] is not None]
    res = {"prefix": prefix, "samples": len(samples), "rc": rc, "invalid": []}
    res["t_reconstructed"] = bool(samples and samples[0].get("t_reconstructed"))
    res["wall_s"] = tv.get("wall_s", (samples[-1]["t"] if samples else None))
    res["time_v_max_rss_mb"] = tv.get("max_rss_mb")
    res["majflt"] = tv.get("majflt", max((s["majflt"] or 0) for s in samples) if samples else None)

    if live:
        pk = max(live, key=lambda s: s["rss"])
        res["peak_rss_mb"], res["t_peak_s"] = pk["rss"], pk["t"]
    ma = [s for s in samples if s["memavail"] is not None]
    if ma:
        mn = min(ma, key=lambda s: s["memavail"])
        res["min_memavail_mb"], res["t_min_memavail_s"] = mn["memavail"], mn["t"]
    sf = [s["swapfree"] for s in samples if s["swapfree"] is not None]
    if sf:
        # swap the run added: the box may already have swap in use when the run starts
        res["max_swap_used_mb"] = max(0.0, sf[0] - min(sf))

    # phases
    fe_end = None
    for i in range(1, len(samples)):
        if samples[i]["gc_cpu"] - samples[i - 1]["gc_cpu"] > GC_RISE_S:
            fe_end = i
    if fe_end is None:
        fe_end = len(samples) - 1 if samples else None
    phases = {}
    if samples and fe_end is not None:
        fe = samples[: fe_end + 1]
        be = samples[fe_end + 1:]
        phases["FE"] = phase_stats(fe)
        phases["BE"] = phase_stats(be)
        # each rise in thread count: [first sample, last sample]; adjacent rising samples merge
        starts = []
        for i in range(1, len(be)):
            a, b = be[i - 1]["threads"], be[i]["threads"]
            if a is not None and b is not None and b > a and (not starts or i > starts[-1][1] + 1):
                starts.append([i, i])
            elif a is not None and b is not None and b > a:
                starts[-1][1] = i
        if len(starts) >= 1:
            phases["BE.mlir_ctx_s"] = be[starts[0][0]]["t"]
        if len(starts) >= 2:
            par = [s for s in be[starts[1][0]:] if s["threads"] is not None
                   and s["threads"] >= be[starts[1][1]]["threads"]]
            phases["BE.parallel_codegen"] = phase_stats(par) if par else None
            phases["BE.parallel_codegen_threads"] = be[starts[1][1]]["threads"]
    res["phases"] = phases

    # gc reports
    reports = []
    for line in stderr.splitlines():
        m = REPORT_RE.match(line)
        if not m:
            continue
        kv = {}
        for tok in m.group(1).split():
            k, _, v = tok.partition("=")
            kv[k] = v
        reports.append(kv)
    have_ngc = any(s["ngc"] is not None for s in samples)
    for n, kv in enumerate(reports, 1):
        entry = {"fields": kv}
        if have_ngc:
            idx = next((i for i, s in enumerate(samples) if (s["ngc"] or 0) >= n), None)
            if idx is not None:
                entry["t_s"] = samples[idx]["t"]
                entry["rss_after_mb"] = samples[idx]["rss"]
                entry["rss_before_mb"] = samples[idx - 1]["rss"] if idx > 0 else None
        reports[n - 1] = entry
    res["gc_reports"] = reports

    # validity
    if "signal" in tv:
        res["invalid"].append("time -v: terminated by signal %d" % tv["signal"])
    if tv.get("exit_status", 0) != 0:
        res["invalid"].append("exit status %d" % tv["exit_status"])
    if not tv:
        res["invalid"].append("no time -v output")
    if re.search(r"\[gc-stats\] SIG", stderr):
        res["invalid"].append("[gc-stats] SIG in stderr")
    watch = meta.get("watch")
    if watch:
        path = watch if os.path.isabs(watch) else os.path.join(meta.get("cwd", "."), watch)
        last_out = samples[-1]["out"] if samples else None
        if not os.path.exists(path) and not last_out:
            res["invalid"].append("output file missing: %s" % watch)
    run_start = None
    worst = 0.0
    for s in samples:
        if s["memavail"] is not None and s["memavail"] < REAPER_MB:
            run_start = s["t"] if run_start is None else run_start
            worst = max(worst, s["t"] - run_start)
        else:
            run_start = None
    if worst > REAPER_S:
        res["invalid"].append("MemAvailable < %d MB for %.1f s (reaper zone)" % (REAPER_MB, worst))
    return res


def fmt(v, nd=0):
    if v is None:
        return "-"
    if isinstance(v, float):
        return ("%%.%df" % nd) % v
    return str(v)


def print_run(r):
    print("== %s%s" % (r["prefix"], "  ** INVALID: " + "; ".join(r["invalid"]) if r["invalid"] else ""))
    if r["t_reconstructed"]:
        print("   (old sampler format: time axis reconstructed from the time -v wall clock)")
    print("   wall %s s, rc %s, samples %d" % (fmt(r["wall_s"], 1), fmt(r["rc"]), r["samples"]))
    print("   peak RSS %s MB sampled at %s s, %s MB per time -v; min MemAvailable %s MB at %s s;"
          " max swap used %s MB; major faults %s"
          % (fmt(r.get("peak_rss_mb")), fmt(r.get("t_peak_s"), 1), fmt(r["time_v_max_rss_mb"]),
             fmt(r.get("min_memavail_mb")), fmt(r.get("t_min_memavail_s"), 1),
             fmt(r.get("max_swap_used_mb")), fmt(r["majflt"])))
    ph = r["phases"]
    for name in ("FE", "BE", "BE.parallel_codegen"):
        p = ph.get(name)
        if p:
            print("   %-20s %7s-%-7s s  dur %7s s  peak %6s MB  mean %6s MB"
                  % (name, fmt(p["start_s"], 1), fmt(p["end_s"], 1), fmt(p["dur_s"], 1),
                     fmt(p["peak_rss_mb"]), fmt(p["mean_rss_mb"])))
    if "BE.mlir_ctx_s" in ph:
        print("   BE MLIR context at %s s; parallel codegen threads %s"
              % (fmt(ph["BE.mlir_ctx_s"], 1), fmt(ph.get("BE.parallel_codegen_threads"))))
    for e in r["gc_reports"]:
        f = e["fields"]
        print("   [gc-report] t=%s s rss %s>%s MB  point=%s kind=%s total_ms=%s live_mb=%s rss_mb=%s"
              % (fmt(e.get("t_s"), 1), fmt(e.get("rss_before_mb")), fmt(e.get("rss_after_mb")),
                 f.get("point", "-"), f.get("kind", "-"), f.get("total_ms", "-"),
                 f.get("live_mb", "-"), f.get("rss_mb", "-")))


MEDIAN_KEYS = ("wall_s", "peak_rss_mb", "time_v_max_rss_mb", "t_peak_s", "min_memavail_mb",
               "max_swap_used_mb", "majflt")


def main(argv):
    as_json = "--json" in argv
    prefixes = [a for a in argv if a != "--json"]
    if not prefixes:
        print(__doc__, file=sys.stderr)
        return 2
    runs = [summarise(p) for p in prefixes]
    groups = {}
    for r in runs:
        m = re.match(r"^(.*)-r\d+$", r["prefix"])
        if m:
            groups.setdefault(m.group(1), []).append(r)
    medians = {}
    for base, rs in groups.items():
        if len(rs) < 2:
            continue
        med = {"runs": len(rs), "invalid_runs": sum(1 for r in rs if r["invalid"])}
        for k in MEDIAN_KEYS:
            vals = [r.get(k) for r in rs if r.get(k) is not None]
            med[k] = statistics.median(vals) if vals else None
            med[k + "_spread"] = (max(vals) - min(vals)) if vals else None
        for ph in ("FE", "BE"):
            for k in ("dur_s", "peak_rss_mb"):
                vals = [r["phases"][ph][k] for r in rs
                        if r["phases"].get(ph) and r["phases"][ph].get(k) is not None]
                med[ph + "." + k] = statistics.median(vals) if vals else None
        medians[base] = med
    if as_json:
        json.dump({"runs": runs, "medians": medians}, sys.stdout, indent=1)
        print()
        return 0
    for r in runs:
        print_run(r)
    for base, m in medians.items():
        print("== median of %s-r* (%d runs, %d invalid)" % (base, m["runs"], m["invalid_runs"]))
        print("   wall %s s (spread %s); peak RSS %s MB sampled (spread %s), %s MB per time -v;"
              " min MemAvailable %s MB; max swap %s MB; major faults %s"
              % (fmt(m["wall_s"], 1), fmt(m["wall_s_spread"], 1), fmt(m["peak_rss_mb"]),
                 fmt(m["peak_rss_mb_spread"]), fmt(m["time_v_max_rss_mb"]),
                 fmt(m["min_memavail_mb"]), fmt(m["max_swap_used_mb"]), fmt(m["majflt"])))
        print("   FE %s s / %s MB; BE %s s / %s MB"
              % (fmt(m["FE.dur_s"], 1), fmt(m["FE.peak_rss_mb"]), fmt(m["BE.dur_s"], 1),
                 fmt(m["BE.peak_rss_mb"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
