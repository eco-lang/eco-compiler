#!/usr/bin/env python3
"""Format a side-by-side table of GNU `/usr/bin/time -v` output for one or
more bootstrap pipeline stages.

Usage:
    print-mlir-timings.py TITLE [LABEL TIME_LOG OUTPUT_FILE]...

Each `(LABEL, TIME_LOG, OUTPUT_FILE)` triplet becomes one table column. The
script handles arbitrarily many stages. Missing logs / outputs render as '-'
so the script is safe to invoke before any stage has run. Binary outputs
(e.g. native ELF) report no line count; text outputs report bytes + lines.
"""

import os
import sys
from pathlib import Path


def parse_time_log(path):
    """Parse `/usr/bin/time -v` output into a label -> value dict.

    Labels can embed colons inside parens (e.g. `Elapsed (wall clock) time
    (h:mm:ss or m:ss)`), so split on the LAST ': ' separator.
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


def is_binary(path, sniff_bytes=4096):
    """Heuristic: file is binary if its first chunk contains any NUL byte."""
    try:
        with open(path, "rb") as f:
            return b"\x00" in f.read(sniff_bytes)
    except OSError:
        return False


def file_stats(path):
    """Return (size_bytes, line_count). line_count is None for binary files."""
    if not Path(path).is_file():
        return None, None
    size = os.path.getsize(path)
    if is_binary(path):
        return size, None
    with open(path, "rb") as f:
        lines = sum(1 for _ in f)
    return size, lines


def fmt_int(value):
    if value is None:
        return "-"
    try:
        return f"{int(value):,}"
    except (TypeError, ValueError):
        return value or "-"


def elapsed_to_seconds(elapsed):
    if not elapsed:
        return None
    parts = elapsed.split(":")
    try:
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
        if len(parts) == 2:
            return int(parts[0]) * 60 + float(parts[1])
    except ValueError:
        return None
    return None


def throughput(time_log, size_bytes):
    if size_bytes is None:
        return "-"
    secs = elapsed_to_seconds(
        time_log.get("Elapsed (wall clock) time (h:mm:ss or m:ss)"))
    if not secs:
        return "-"
    return f"{size_bytes / 1024 / secs:.1f} KiB/s"


def main():
    if len(sys.argv) < 5 or (len(sys.argv) - 2) % 3 != 0:
        sys.exit(
            "usage: print-mlir-timings.py TITLE [LABEL TIME_LOG OUTPUT_FILE]...")
    title = sys.argv[1]
    triplets = sys.argv[2:]

    stages = []
    for i in range(0, len(triplets), 3):
        label, log_path, out_path = triplets[i:i + 3]
        time_log = parse_time_log(log_path)
        size, lines = file_stats(out_path)
        stages.append({
            "label": label,
            "time": time_log,
            "size": size,
            "lines": lines,
        })

    def t(stage, key):
        return stage["time"].get(key, "-")

    rows = [
        ("Wall clock",
            lambda s: t(s, "Elapsed (wall clock) time (h:mm:ss or m:ss)")),
        ("User CPU (s)",
            lambda s: t(s, "User time (seconds)")),
        ("System CPU (s)",
            lambda s: t(s, "System time (seconds)")),
        ("CPU usage",
            lambda s: t(s, "Percent of CPU this job got")),
        ("Peak RSS",
            lambda s: humanize_kib(s["time"].get(
                "Maximum resident set size (kbytes)"))),
        ("Minor page faults",
            lambda s: fmt_int(s["time"].get(
                "Minor (reclaiming a frame) page faults"))),
        ("Major page faults",
            lambda s: fmt_int(s["time"].get(
                "Major (requiring I/O) page faults"))),
        ("Vol. ctx switches",
            lambda s: fmt_int(s["time"].get("Voluntary context switches"))),
        ("Invol. ctx switches",
            lambda s: fmt_int(s["time"].get("Involuntary context switches"))),
        ("FS outputs (blocks)",
            lambda s: fmt_int(s["time"].get("File system outputs"))),
        ("Output size",
            lambda s: humanize_bytes(s["size"])),
        ("Output lines",
            lambda s: fmt_int(s["lines"])),
        ("Output throughput",
            lambda s: throughput(s["time"], s["size"])),
    ]

    metric_col = "Metric"
    label_w = max(len(metric_col), max(len(r[0]) for r in rows))
    col_widths = []
    for stage in stages:
        widest = max(len(str(getter(stage))) for _, getter in rows)
        col_widths.append(max(len(stage["label"]), widest))
    total_w = label_w + sum(col_widths) + 2 * (len(stages) + 1)

    def line(parts, sep="  "):
        return "  " + sep.join(parts)

    print()
    print("=" * total_w)
    print(("  " + title).ljust(total_w))
    print("=" * total_w)
    print(line([f"{metric_col:<{label_w}}"]
               + [f"{s['label']:>{w}}" for s, w in zip(stages, col_widths)]))
    print(line(["-" * label_w] + ["-" * w for w in col_widths]))
    for label, getter in rows:
        print(line([f"{label:<{label_w}}"]
                   + [f"{str(getter(s)):>{w}}"
                      for s, w in zip(stages, col_widths)]))
    print("=" * total_w)
    print()


if __name__ == "__main__":
    main()
