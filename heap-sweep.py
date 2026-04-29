#!/usr/bin/env python3
"""
Sweep HeapConfig parameters by re-running Stage 7 with different
configs and compare GC behaviour. Each run is 5 minutes; results
are appended to /tmp/heap-sweep/results.tsv as soon as each run
completes (so partial results survive interruption).
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

SWEEP_DIR = Path("/tmp/heap-sweep")
SWEEP_DIR.mkdir(parents=True, exist_ok=True)
RESULTS = SWEEP_DIR / "results.tsv"

ECO_COMPILER = "/work/compiler/build-kernel/bin/eco-compiler"
BUILD_KERNEL = Path("/work/compiler/build-kernel")
ELM_ENTRY = "/work/compiler/src/Terminal/Main.elm"

WALL_S = 300        # 5-minute timeout per run
KILL_AFTER = 10

BASELINE = {
    "max_heap_size":                 "24G",
    "initial_old_gen_size":          "16M",
    "alloc_buffer_size":             "128K",
    "nursery_block_count":           64,
    "promotion_age":                 2,
    "nursery_gc_threshold":          0.9,
    "nursery_growth_threshold":      0.1,
    "major_gc_initiating_occupancy": 0.75,
    "major_gc_target_utilization":   0.50,
    "use_hybrid_dfs":                True,
    "large_object_threshold":        "8K",
    "decommit_on_oldgen_release":    True,
}

# Each variant: (name, short_change_label, override_dict)
VARIANTS = [
    ("baseline",     "(defaults)",                     {}),
    # A. Nursery sizing — block_count alone
    ("A_nb16",       "nursery_block_count=16",         {"nursery_block_count": 16}),
    ("A_nb32",       "nursery_block_count=32",         {"nursery_block_count": 32}),
    ("A_nb128",      "nursery_block_count=128",        {"nursery_block_count": 128}),
    # B. Promotion age — growth_threshold pinned at 0.1
    ("B_age1",       "promotion_age=1",                {"promotion_age": 1}),
    ("B_age3",       "promotion_age=3",                {"promotion_age": 3}),
    # C. Major GC trigger / shrink
    ("C1_early",     "init=0.50 target=0.30",          {"major_gc_initiating_occupancy": 0.50, "major_gc_target_utilization": 0.30}),
    ("C2_late",      "init=0.85",                      {"major_gc_initiating_occupancy": 0.85}),
    ("C3_tight",     "target=0.70",                    {"major_gc_target_utilization": 0.70}),
    # D. Large-object threshold
    ("D1_lot4K",     "LOT=4K",                         {"large_object_threshold": "4K"}),
    ("D2_lot32K",    "LOT=32K",                        {"large_object_threshold": "32K"}),
    # E. Page size — knock-on effect on nursery total
    ("E1_page64K",   "alloc_buffer_size=64K",          {"alloc_buffer_size": "64K"}),
    ("E2_page256K",  "alloc_buffer_size=256K",         {"alloc_buffer_size": "256K"}),
]


HEADER = ["name", "change",
          "wall_s", "major_gcs", "minor_gcs",
          "major_s", "minor_s",
          "helper_min_s", "helper_mut_s", "helper_s",
          "mutator_s", "mutator_pct",
          "bytes_alloc_MB", "alloc_MBps", "objs_alloc",
          "peak_commit_MB", "final_live_MB"]


def write_header_if_new() -> set[str]:
    """Returns the set of variant names already in results.tsv."""
    done = set()
    if RESULTS.exists():
        with RESULTS.open() as f:
            lines = f.read().splitlines()
        if lines and lines[0].split("\t") == HEADER:
            for line in lines[1:]:
                cols = line.split("\t")
                if cols:
                    done.add(cols[0])
            return done
    with RESULTS.open("w") as f:
        f.write("\t".join(HEADER) + "\n")
    return done


def write_config(name: str, overrides: dict) -> Path:
    cfg = BASELINE | overrides
    path = SWEEP_DIR / f"{name}.json"
    with path.open("w") as f:
        json.dump(cfg, f, indent=2)
    return path


def parse_float(text: str, pattern: str) -> float | None:
    """First numeric capture from `pattern` against `text`, or None."""
    m = re.search(pattern, text)
    if not m:
        return None
    return float(m.group(1))


def parse_int(text: str, pattern: str) -> int | None:
    m = re.search(pattern, text)
    if not m:
        return None
    return int(m.group(1))


def _time_to_seconds(value: float, unit: str) -> float:
    """Convert formatTime output (ns/µs/ms/s) to seconds."""
    if unit == "s":
        return value
    if unit == "ms":
        return value / 1_000.0
    # formatTime emits the literal Greek mu (µ) for microseconds.
    if unit in ("µs", "us"):
        return value / 1_000_000.0
    if unit == "ns":
        return value / 1_000_000_000.0
    raise ValueError(f"unknown time unit {unit!r}")


# Captures the number followed by its formatTime unit. Word boundary on the
# unit prevents 's' from matching the 's' in 'ms'/'µs'/'ns'.
_TIME_RE = r"([0-9.]+)\s+(ns|µs|us|ms|s)\b"


def parse_stats(out_text: str, err_text: str, wall_s: float) -> dict:
    # GC stats summary lives in stdout (printed by SIGTERM signal handler).
    major_gcs = parse_int(out_text, r"Major GC cycles:\s+(\d+)") or 0
    minor_gcs = parse_int(out_text, r"Minor GC cycles:\s+(\d+)") or 0
    bytes_mb = parse_float(out_text, r"Bytes allocated:\s+([0-9.]+)\s*MB") or 0.0
    objs = parse_int(out_text, r"Objects allocated:\s+(\d+)") or 0

    # "Total time" appears in BOTH "Major GC Timing:" and "Minor GC Timing:"
    # blocks. The runtime's formatTime emits ns/µs/ms/s depending on
    # magnitude; capture the unit and normalise to seconds.
    #
    # As of the inline-helper-attribution change, four GC buckets sum to
    # the total GC wall time:
    #   minor_s  — pure nursery copy (helper subtracted per cycle)
    #   major_s  — sum of STW major cycles
    #   helper_in_minor_s  — mark/sweep work paced inside minor pauses
    #   helper_in_mutator_s — mark/sweep work paced inside mutator allocs
    # The remainder is true mutator work:
    #   mutator_s = wall_s - minor_s - major_s
    #             - helper_in_minor_s - helper_in_mutator_s
    major_match = re.search(
        r"Major GC Timing:.*?Total time:\s+" + _TIME_RE,
        out_text, re.DOTALL)
    minor_match = re.search(
        r"Minor GC Timing:.*?Total time:\s+" + _TIME_RE,
        out_text, re.DOTALL)
    helper_minor_match = re.search(
        r"In minor pauses:\s+" + _TIME_RE, out_text)
    helper_mutator_match = re.search(
        r"In mutator alloc:\s+" + _TIME_RE, out_text)

    major_s = (_time_to_seconds(float(major_match.group(1)), major_match.group(2))
               if major_match else 0.0)
    minor_s = (_time_to_seconds(float(minor_match.group(1)), minor_match.group(2))
               if minor_match else 0.0)
    helper_in_minor_s = (
        _time_to_seconds(float(helper_minor_match.group(1)),
                         helper_minor_match.group(2))
        if helper_minor_match else 0.0)
    helper_in_mutator_s = (
        _time_to_seconds(float(helper_mutator_match.group(1)),
                         helper_mutator_match.group(2))
        if helper_mutator_match else 0.0)

    helper_s = helper_in_minor_s + helper_in_mutator_s
    raw_mutator_s = wall_s - major_s - minor_s - helper_s
    mutator_s = max(0.0, raw_mutator_s)

    # Sanity check: total GC time must not exceed wall clock. If this trips,
    # there's over-counting somewhere — most likely a regex capturing the
    # same time twice, or a runtime clock-skew between the timer used for
    # GC measurement and the Python wall-clock measurement.
    if raw_mutator_s < -0.5:
        print(f"  WARN: GC bucket sum {minor_s + major_s + helper_s:.2f}s "
              f"exceeds wall {wall_s:.2f}s by {-raw_mutator_s:.2f}s",
              flush=True)
    mutator_pct = (mutator_s / wall_s * 100.0) if wall_s > 0 else 0.0
    alloc_mbps = bytes_mb / wall_s if wall_s > 0 else 0.0

    # Peak committed from heap-trace (stderr).
    peak = 0.0
    for m in re.finditer(r"tl\.committed=([0-9.]+)\s*MB", err_text):
        v = float(m.group(1))
        if v > peak:
            peak = v

    # Final live (last tl.live value seen in stderr).
    live_matches = re.findall(r"tl\.live=([0-9.]+)\s*MB", err_text)
    final_live = float(live_matches[-1]) if live_matches else 0.0

    return {
        "wall_s": f"{wall_s:.1f}",
        "major_gcs": major_gcs,
        "minor_gcs": minor_gcs,
        "major_s": f"{major_s:.2f}",
        "minor_s": f"{minor_s:.2f}",
        "helper_min_s": f"{helper_in_minor_s:.2f}",
        "helper_mut_s": f"{helper_in_mutator_s:.2f}",
        "helper_s": f"{helper_s:.2f}",
        "mutator_s": f"{mutator_s:.2f}",
        "mutator_pct": f"{mutator_pct:.1f}",
        "bytes_alloc_MB": f"{bytes_mb:.2f}",
        "alloc_MBps": f"{alloc_mbps:.2f}",
        "objs_alloc": objs,
        "peak_commit_MB": f"{peak:.2f}",
        "final_live_MB": f"{final_live:.2f}",
    }


def run_variant(name: str, change: str, overrides: dict):
    print(f"\n=== {name}  ({change}) ===", flush=True)
    cfg_path = write_config(name, overrides)

    out_path = SWEEP_DIR / f"{name}.out"
    err_path = SWEEP_DIR / f"{name}.err"

    # Remove the previous output mlir so we don't confuse "didn't write".
    boot_mlir = BUILD_KERNEL / "bin" / "eco-compiler-boot.mlir"
    if boot_mlir.exists():
        boot_mlir.unlink()

    env = os.environ | {
        "ECO_HEAP_CONFIG": str(cfg_path),
        "ECO_HEAP_TRACE": "1",
        "ECO_GC_PHASE_PROFILE": "1",
    }

    cmd = [
        "/usr/bin/timeout", f"--kill-after={KILL_AFTER}s", str(WALL_S),
        ECO_COMPILER, "make",
        "--optimize",
        "--kernel-package", "eco/compiler",
        "--local-package", "eco/kernel=/work/eco-kernel-cpp",
        "--output=bin/eco-compiler-boot.mlir",
        ELM_ENTRY,
    ]

    t0 = time.time()
    with out_path.open("wb") as out, err_path.open("wb") as err:
        rc = subprocess.run(cmd, cwd=BUILD_KERNEL, env=env,
                            stdout=out, stderr=err).returncode
    elapsed = time.time() - t0

    out_text = out_path.read_text(errors="replace")
    err_text = err_path.read_text(errors="replace")

    # If timeout, wall clock = WALL_S; otherwise use measured elapsed.
    wall_s = float(WALL_S) if rc == 124 else elapsed

    stats = parse_stats(out_text, err_text, wall_s)
    stats["name"] = name
    stats["change"] = change

    row = "\t".join(str(stats[col]) for col in HEADER)
    with RESULTS.open("a") as f:
        f.write(row + "\n")
    print(f"rc={rc}  {row}", flush=True)


def main():
    done = write_header_if_new()
    print(f"Results file: {RESULTS}", flush=True)
    print(f"Already done: {sorted(done)}", flush=True)

    for name, change, overrides in VARIANTS:
        if name in done:
            print(f"\n=== SKIP {name} (already in results.tsv) ===", flush=True)
            continue
        run_variant(name, change, overrides)

    print("\n=== Sweep complete ===", flush=True)


if __name__ == "__main__":
    main()
