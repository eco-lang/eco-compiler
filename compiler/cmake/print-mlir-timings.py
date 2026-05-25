#!/usr/bin/env python3
"""Format a comparison table of GNU `/usr/bin/time -v` output for the two
front-end MLIR-emit stages of the bootstrap chain.

  Stage 5  — eco-boot-2.js (Node)         → eco-compiler.mlir
  Stage 7a — eco-compiler (native ELF)    → eco-compiler-boot.mlir

Usage:
    print-mlir-timings.py LOG5 LOG7A MLIR5 MLIR7A

Missing log or output files render as '-' so the script is safe to invoke
before either stage has run.
"""

import os
import sys
from pathlib import Path


def parse_time_log(path):
    """Parse a `/usr/bin/time -v` output file into a label -> value dict.

    Labels can embed colons inside parens (e.g. `Elapsed (wall clock) time
    (h:mm:ss or m:ss)`), so we split on the LAST ": " separator instead of
    the first colon.
    """
    out = {}
    if not Path(path).is_file():
        return out
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if ": " not in line:
                continue
            label, _, value = line.rpartition(": ")
            out[label.strip()] = value.strip()
    return out


def humanize_kib(value):
    try:
        kib = int(value)
    except (TypeError, ValueError):
        return value or "-"
    if kib >= 1024 * 1024:
        return f"{kib / (1024 * 1024):.2f} GiB"
    return f"{kib / 1024:.1f} MiB"


def humanize_bytes(n):
    if n is None:
        return "-"
    if n >= 1024 * 1024:
        return f"{n / (1024 * 1024):.2f} MiB ({n:,} B)"
    if n >= 1024:
        return f"{n / 1024:.1f} KiB ({n:,} B)"
    return f"{n} B"


def file_stats(path):
    if not Path(path).is_file():
        return None, None
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        lines = sum(1 for _ in f)
    return size, lines


def fmt_int(value):
    try:
        return f"{int(value):,}"
    except (TypeError, ValueError):
        return value or "-"


def throughput(time_log, file_size):
    """KB of MLIR text emitted per wall-clock second."""
    if file_size is None:
        return "-"
    elapsed = time_log.get("Elapsed (wall clock) time (h:mm:ss or m:ss)")
    if not elapsed:
        return "-"
    # Format is either "h:mm:ss" or "m:ss[.ss]".
    parts = elapsed.split(":")
    try:
        if len(parts) == 3:
            secs = int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
        elif len(parts) == 2:
            secs = int(parts[0]) * 60 + float(parts[1])
        else:
            return "-"
    except ValueError:
        return "-"
    if secs <= 0:
        return "-"
    return f"{file_size / 1024 / secs:.1f} KiB/s"


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: print-mlir-timings.py LOG5 LOG7A MLIR5 MLIR7A")
    log5_path, log7a_path, mlir5_path, mlir7a_path = sys.argv[1:5]

    t5 = parse_time_log(log5_path)
    t7a = parse_time_log(log7a_path)
    size5, lines5 = file_stats(mlir5_path)
    size7a, lines7a = file_stats(mlir7a_path)

    rows = [
        ("Wall clock",
         t5.get("Elapsed (wall clock) time (h:mm:ss or m:ss)", "-"),
         t7a.get("Elapsed (wall clock) time (h:mm:ss or m:ss)", "-")),
        ("User CPU (s)",
         t5.get("User time (seconds)", "-"),
         t7a.get("User time (seconds)", "-")),
        ("System CPU (s)",
         t5.get("System time (seconds)", "-"),
         t7a.get("System time (seconds)", "-")),
        ("CPU usage",
         t5.get("Percent of CPU this job got", "-"),
         t7a.get("Percent of CPU this job got", "-")),
        ("Peak RSS",
         humanize_kib(t5.get("Maximum resident set size (kbytes)")),
         humanize_kib(t7a.get("Maximum resident set size (kbytes)"))),
        ("Minor page faults",
         fmt_int(t5.get("Minor (reclaiming a frame) page faults")),
         fmt_int(t7a.get("Minor (reclaiming a frame) page faults"))),
        ("Major page faults",
         fmt_int(t5.get("Major (requiring I/O) page faults")),
         fmt_int(t7a.get("Major (requiring I/O) page faults"))),
        ("Vol. ctx switches",
         fmt_int(t5.get("Voluntary context switches")),
         fmt_int(t7a.get("Voluntary context switches"))),
        ("Invol. ctx switches",
         fmt_int(t5.get("Involuntary context switches")),
         fmt_int(t7a.get("Involuntary context switches"))),
        ("FS outputs (blocks)",
         fmt_int(t5.get("File system outputs")),
         fmt_int(t7a.get("File system outputs"))),
        ("MLIR output size",
         humanize_bytes(size5),
         humanize_bytes(size7a)),
        ("MLIR output lines",
         fmt_int(lines5),
         fmt_int(lines7a)),
        ("MLIR throughput",
         throughput(t5, size5),
         throughput(t7a, size7a)),
    ]

    col1, col2, col3 = "Metric", "Stage 5 (JS → MLIR)", "Stage 7a (ELF → MLIR)"
    w1 = max(len(col1), max(len(r[0]) for r in rows))
    w2 = max(len(col2), max(len(str(r[1])) for r in rows))
    w3 = max(len(col3), max(len(str(r[2])) for r in rows))
    total = w1 + w2 + w3 + 6

    print()
    print("=" * total)
    print("  MLIR front-end compile timings".ljust(total))
    print("=" * total)
    print(f"  {col1:<{w1}}  {col2:>{w2}}  {col3:>{w3}}")
    print(f"  {'-' * w1}  {'-' * w2}  {'-' * w3}")
    for label, a, b in rows:
        print(f"  {label:<{w1}}  {str(a):>{w2}}  {str(b):>{w3}}")
    print("=" * total)
    print()


if __name__ == "__main__":
    main()
