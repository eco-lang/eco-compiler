#!/usr/bin/env python3
"""
Heap profiler for the Eco runtime.

Two modes:
  run    — compile Stage 7 once with one heap-config JSON.
  sweep  — compile Stage 7 once per entry of a VARIANTS matrix
           (the built-in one in this file, or a JSON file passed via
           `--variants-file`).

Each invocation creates one timestamped folder under
    <results_root>/<machine>/<YYYY-MM-DDTHH-MM-SSZ>__<label>/
containing:
  - report.md                   Markdown summary linking the per-block TSVs
  - runs.tsv                    one summary row per variant (resume marker)
  - args.json                   CLI args, resolved paths, rebuild outcome
  - variants/<name>/            with per-variant TSVs and logs.

`<results_root>` and `<machine>` come from `heap-profile.local.json` next to
this script (created on first run via interactive prompt) or from CLI flags.

All metric files are tab-separated (`.tsv`).
"""

import argparse
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent
ECO_COMPILER = REPO_ROOT / "compiler/build-kernel/bin/eco-compiler"
ECO_BOOT_NATIVE = REPO_ROOT / "build/runtime/src/codegen/eco-boot-native"
ECO_COMPILER_MLIR = REPO_ROOT / "compiler/build-kernel/bin/eco-compiler.mlir"
BUILD_KERNEL = REPO_ROOT / "compiler/build-kernel"
ECO_BOOT_2_RUNNER = BUILD_KERNEL / "bin/eco-boot-2-runner.js"
ECO_KERNEL_CPP = REPO_ROOT / "eco-kernel-cpp"
ELM_ENTRY = REPO_ROOT / "compiler/src/Terminal/Main.elm"
COMPILER_SRC = REPO_ROOT / "compiler/src"
RUNTIME_SRC = REPO_ROOT / "runtime/src"
DEFAULT_HEAP_CONFIG = REPO_ROOT / "compiler/build-kernel/heap-config.json"
LOCAL_CONFIG = REPO_ROOT / "heap-profile.local.json"

KILL_AFTER_S = 10
DEFAULT_WALL_SECONDS = 60

# ---------------------------------------------------------------------------
# Variants (hard-coded for sweep mode)
# ---------------------------------------------------------------------------

BASELINE_HEAP = {
    "max_heap_size":                 "24G",
    "initial_old_gen_size":          "16M",
    "alloc_buffer_size":             "512K",
    "nursery_block_count":           64,
    "promotion_age":                 2,
    "nursery_gc_threshold":          0.9,
    "nursery_growth_threshold":      0.1,
    "major_gc_initiating_occupancy": 0.85,
    "major_gc_target_utilization":   0.70,
    "use_hybrid_dfs":                True,
    "large_object_threshold":        "16K",
    "decommit_on_oldgen_release":    True,
}

VARIANTS = [
    ("baseline",     "(defaults)",                     {}),
    # A. Nursery sizing
    ("A_nb16",       "nursery_block_count=16",         {"nursery_block_count": 16}),
    ("A_nb32",       "nursery_block_count=32",         {"nursery_block_count": 32}),
    ("A_nb128",      "nursery_block_count=128",        {"nursery_block_count": 128}),
    # B. Promotion age
    ("B_age1",       "promotion_age=1",                {"promotion_age": 1}),
    ("B_age3",       "promotion_age=3",                {"promotion_age": 3}),
    # C. Major GC trigger / shrink
    ("C1_early",     "init=0.50 target=0.30",          {"major_gc_initiating_occupancy": 0.50, "major_gc_target_utilization": 0.30}),
    ("C2_late",      "init=0.85",                      {"major_gc_initiating_occupancy": 0.85}),
    ("C3_tight",     "target=0.70",                    {"major_gc_target_utilization": 0.70}),
    # D. Large-object threshold
    ("D1_lot4K",     "LOT=4K",                         {"large_object_threshold": "4K"}),
    ("D2_lot32K",    "LOT=32K",                        {"large_object_threshold": "32K"}),
    # E. Page size
    ("E1_page64K",   "alloc_buffer_size=64K",          {"alloc_buffer_size": "64K"}),
    ("E2_page256K",  "alloc_buffer_size=256K",         {"alloc_buffer_size": "256K"}),
]


def load_variants_file(path: Path) -> list[tuple[str, str, dict]]:
    """Load a sweep matrix from a JSON file. The file must be a list of
    objects with keys 'name', 'change', 'overrides'. 'change' defaults to
    a `key=value` summary of overrides if omitted."""
    data = json.loads(Path(path).read_text())
    if not isinstance(data, list):
        sys.exit(f"ERROR: {path}: top level must be a list of variants")
    out: list[tuple[str, str, dict]] = []
    seen: set[str] = set()
    for i, item in enumerate(data):
        if not isinstance(item, dict):
            sys.exit(f"ERROR: {path}[{i}]: each variant must be an object")
        name = item.get("name")
        if not name or not isinstance(name, str):
            sys.exit(f"ERROR: {path}[{i}]: missing string 'name'")
        if name in seen:
            sys.exit(f"ERROR: {path}: duplicate variant name {name!r}")
        seen.add(name)
        overrides = item.get("overrides", {})
        if not isinstance(overrides, dict):
            sys.exit(f"ERROR: {path}[{i}]: 'overrides' must be an object")
        change = item.get("change") or ", ".join(
            f"{k}={v}" for k, v in overrides.items()) or "(no overrides)"
        out.append((name, change, overrides))
    return out

SUMMARY_COLUMNS = [
    "name", "change",
    "wall_s", "major_gcs", "minor_gcs",
    "major_s", "minor_s",
    "helper_min_s", "helper_mut_s", "helper_s",
    "mutator_s", "mutator_pct",
    "bytes_alloc_MB", "alloc_MBps", "objs_alloc",
    "peak_commit_MB", "final_live_MB",
]


# ---------------------------------------------------------------------------
# TSV writer
# ---------------------------------------------------------------------------

def _format_field(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    return str(v)


def write_tsv(path: Path, columns: list[str], rows: list[dict]) -> None:
    """Write one TSV file. No quoting; raises if any value contains \\t or \\n."""
    with path.open("w") as f:
        f.write("\t".join(columns) + "\n")
        for row in rows:
            cells = []
            for c in columns:
                cell = _format_field(row.get(c, ""))
                if "\t" in cell or "\n" in cell:
                    raise ValueError(
                        f"TSV value for column {c!r} in {path} "
                        f"contains tab/newline: {cell!r}")
                cells.append(cell)
            f.write("\t".join(cells) + "\n")


def append_tsv_row(path: Path, columns: list[str], row: dict) -> None:
    """Append one row; writes the header if the file does not exist."""
    new_file = not path.exists()
    with path.open("a") as f:
        if new_file:
            f.write("\t".join(columns) + "\n")
        cells = []
        for c in columns:
            cell = _format_field(row.get(c, ""))
            if "\t" in cell or "\n" in cell:
                raise ValueError(
                    f"TSV value for column {c!r} contains tab/newline: {cell!r}")
            cells.append(cell)
        f.write("\t".join(cells) + "\n")


# ---------------------------------------------------------------------------
# Local config (machine name + results root)
# ---------------------------------------------------------------------------

def load_or_prompt_local_config(no_prompt: bool) -> dict:
    if LOCAL_CONFIG.exists():
        return json.loads(LOCAL_CONFIG.read_text())
    if no_prompt:
        sys.exit(
            f"ERROR: {LOCAL_CONFIG} does not exist and --no-prompt was set.\n"
            f"Create one based on heap-profile.local.example.json.")
    print(f"No local config at {LOCAL_CONFIG}.")
    print("Set up where heap-profile results should live on this machine.")
    suggested_machine = socket.gethostname() or "machine"
    machine = input(f"  machine_name [{suggested_machine}]: ").strip()
    if not machine:
        machine = suggested_machine
    suggested_root = "/tmp/heap-profile"
    results_root = input(f"  results_root [{suggested_root}]: ").strip()
    if not results_root:
        results_root = suggested_root
    cfg = {"machine_name": machine, "results_root": results_root}
    LOCAL_CONFIG.write_text(json.dumps(cfg, indent=2) + "\n")
    print(f"Wrote {LOCAL_CONFIG}.")
    return cfg


def resolve_paths(args) -> tuple[str, Path]:
    cfg = load_or_prompt_local_config(args.no_prompt)
    machine = args.machine or cfg.get("machine_name")
    results_root = Path(args.results_root or cfg.get("results_root"))
    if not machine or not results_root:
        sys.exit("ERROR: machine_name and results_root must be set.")
    return machine, results_root


# ---------------------------------------------------------------------------
# Build freshness check
# ---------------------------------------------------------------------------

def _newest_mtime_under(root: Path, suffixes: tuple[str, ...]) -> float:
    newest = 0.0
    for p in root.rglob("*"):
        if p.is_file() and p.suffix in suffixes:
            try:
                mt = p.stat().st_mtime
                if mt > newest:
                    newest = mt
            except FileNotFoundError:
                continue
    return newest


def _relink_eco_compiler() -> None:
    """Re-lower eco-compiler.mlir to the eco-compiler ELF via eco-boot-native."""
    if not ECO_COMPILER_MLIR.exists():
        sys.exit(f"ERROR: {ECO_COMPILER_MLIR} not found; cannot relink "
                 "eco-compiler. Run Stage 5 first.")
    print(f"[heap-profile] re-lowering {ECO_COMPILER_MLIR.name} via "
          "eco-boot-native...", flush=True)
    subprocess.run(
        [str(ECO_BOOT_NATIVE), str(ECO_COMPILER_MLIR),
         "-o", str(ECO_COMPILER)],
        cwd=REPO_ROOT, check=True)


def _rebuild_compiler_mlir() -> None:
    """Run Stage 5: eco-boot-2-runner.js compiles the Elm sources to MLIR.
    Stale .ecot caches are removed first — JS-output stages do not invalidate
    them, and leftovers from a previous MLIR build crash monomorphization."""
    if not ECO_BOOT_2_RUNNER.exists():
        sys.exit(f"ERROR: {ECO_BOOT_2_RUNNER} not found; cannot rebuild "
                 f"{ECO_COMPILER_MLIR.name}. Run Stages 1-4 first.")
    eco_stuff = BUILD_KERNEL / "eco-stuff"
    if eco_stuff.exists():
        for ecot in eco_stuff.rglob("*.ecot"):
            try:
                ecot.unlink()
            except FileNotFoundError:
                continue
    print(f"[heap-profile] Elm sources newer than {ECO_COMPILER_MLIR.name} — "
          "rebuilding via eco-boot-2-runner...", flush=True)
    subprocess.run(
        ["node", "--stack-size=65536", str(ECO_BOOT_2_RUNNER), "make",
         "--optimize",
         "--kernel-package", "eco/compiler",
         "--local-package", f"eco/kernel={ECO_KERNEL_CPP}",
         f"--output=bin/{ECO_COMPILER_MLIR.name}",
         str(ELM_ENTRY)],
        cwd=BUILD_KERNEL, check=True)


def ensure_binaries_fresh(skip: bool) -> dict:
    """Bring all build artefacts up to date in dependency order:

      1. Rebuild eco-boot-native if any runtime C++ source is newer.
      2. Relink eco-compiler if eco-boot-native or runtime sources moved.
      3. Rebuild eco-compiler.mlir (Stage 5) if any compiler/src .elm
         source is newer than it.
      4. If Stage 5 ran, relink eco-compiler against the fresh .mlir.

    Steps 1-2 (the C++ side) always run before step 3 so that, if a Stage 5
    rebuild is also needed, it happens against an up-to-date toolchain."""
    outcome = {"checked": True, "rebuilt_eco_boot_native": False,
               "relinked_eco_compiler": False,
               "rebuilt_compiler_mlir": False, "skipped": False}
    if skip:
        outcome["checked"] = False
        outcome["skipped"] = True
        return outcome

    src_mtime = _newest_mtime_under(RUNTIME_SRC, (".cpp", ".hpp", ".h"))

    boot_mtime = ECO_BOOT_NATIVE.stat().st_mtime if ECO_BOOT_NATIVE.exists() else 0.0
    if not ECO_BOOT_NATIVE.exists() or boot_mtime < src_mtime:
        print("[heap-profile] runtime sources newer than eco-boot-native — "
              "rebuilding...", flush=True)
        subprocess.run(
            ["cmake", "--build", "build", "--target", "eco-boot-native"],
            cwd=REPO_ROOT, check=True)
        outcome["rebuilt_eco_boot_native"] = True
        boot_mtime = ECO_BOOT_NATIVE.stat().st_mtime

    compiler_mtime = ECO_COMPILER.stat().st_mtime if ECO_COMPILER.exists() else 0.0
    if (not ECO_COMPILER.exists()
            or compiler_mtime < boot_mtime
            or compiler_mtime < src_mtime):
        _relink_eco_compiler()
        outcome["relinked_eco_compiler"] = True

    elm_mtime = _newest_mtime_under(COMPILER_SRC, (".elm",))
    mlir_mtime = (ECO_COMPILER_MLIR.stat().st_mtime
                  if ECO_COMPILER_MLIR.exists() else 0.0)
    if not ECO_COMPILER_MLIR.exists() or mlir_mtime < elm_mtime:
        _rebuild_compiler_mlir()
        outcome["rebuilt_compiler_mlir"] = True
        mlir_mtime = ECO_COMPILER_MLIR.stat().st_mtime
        compiler_mtime = (ECO_COMPILER.stat().st_mtime
                          if ECO_COMPILER.exists() else 0.0)
        if not ECO_COMPILER.exists() or compiler_mtime < mlir_mtime:
            _relink_eco_compiler()
            outcome["relinked_eco_compiler"] = True
    return outcome


# ---------------------------------------------------------------------------
# Stats parsing
# ---------------------------------------------------------------------------

_TIME_RE = r"([0-9.]+)\s+(ns|µs|us|ms|s)\b"


def _t_to_s(value: float, unit: str) -> float:
    if unit == "s":
        return value
    if unit == "ms":
        return value / 1_000.0
    if unit in ("µs", "us"):
        return value / 1_000_000.0
    if unit == "ns":
        return value / 1_000_000_000.0
    raise ValueError(f"unknown time unit {unit!r}")


def _first_int(text: str, pattern: str) -> int:
    m = re.search(pattern, text)
    return int(m.group(1)) if m else 0


def _first_float(text: str, pattern: str) -> float:
    m = re.search(pattern, text)
    return float(m.group(1)) if m else 0.0


def _first_time_seconds(text: str, pattern: str) -> float:
    m = re.search(pattern, text, re.DOTALL)
    if not m:
        return 0.0
    return _t_to_s(float(m.group(1)), m.group(2))


def parse_summary(out_text: str, err_text: str, wall_s: float) -> dict:
    major_gcs = _first_int(out_text, r"Major GC cycles:\s+(\d+)")
    minor_gcs = _first_int(out_text, r"Minor GC cycles:\s+(\d+)")
    bytes_mb = _first_float(out_text, r"Bytes allocated:\s+([0-9.]+)\s*MB")
    objs = _first_int(out_text, r"Objects allocated:\s+(\d+)")
    major_s = _first_time_seconds(
        out_text, r"Major GC Timing:.*?Total time:\s+" + _TIME_RE)
    minor_s = _first_time_seconds(
        out_text, r"Minor GC Timing:.*?Total time:\s+" + _TIME_RE)
    helper_in_minor_s = _first_time_seconds(
        out_text, r"In minor pauses:\s+" + _TIME_RE)
    helper_in_mutator_s = _first_time_seconds(
        out_text, r"In mutator alloc:\s+" + _TIME_RE)

    helper_s = helper_in_minor_s + helper_in_mutator_s
    raw_mutator_s = wall_s - major_s - minor_s - helper_s
    mutator_s = max(0.0, raw_mutator_s)
    mutator_pct = (mutator_s / wall_s * 100.0) if wall_s > 0 else 0.0
    alloc_mbps = bytes_mb / wall_s if wall_s > 0 else 0.0

    peak = 0.0
    for m in re.finditer(r"tl\.committed=([0-9.]+)\s*MB", err_text):
        v = float(m.group(1))
        if v > peak:
            peak = v
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


def parse_alloc_histogram(text: str, header: str) -> list[dict]:
    """Parses one allocation-size histogram block. Each row in the runtime
    output has the form:
        16 B -     32 B: ████ 8987597 (57.7%)
    or the trailing overflow row:
      >=    1 MiB        :  1 (0.0%)
    """
    m = re.search(rf"{re.escape(header)}:\n(.*?)\n\n", text, re.DOTALL)
    if not m:
        return []
    rows = []
    for line in m.group(1).splitlines():
        m2 = re.match(r"\s*(.+?):\s*[█\s]*([0-9]+)\s+\(([0-9.]+)%\)", line)
        if not m2:
            continue
        bucket = m2.group(1).strip()
        count = int(m2.group(2))
        pct = float(m2.group(3))
        rows.append({"bucket": bucket, "count": count, "percent": pct})
    return rows


def parse_residency_histogram(text: str, header_substr: str) -> tuple[list[dict], list[dict]]:
    """Parses one residency histogram block.

    Returns (bucket_rows, total_rows). Byte values are reconstructed from the
    printed MB columns; the runtime emits MB in this block, so we round to
    nearest byte. (Raw byte counters live in GCStats but aren't echoed here.)
    """
    pat = re.compile(
        rf"Old-Gen Page Residency Histogram \({re.escape(header_substr)}[^)]*\):\n"
        r".*?live_frac.*?\n(?P<body>(?:.*\n)+?)\n",
        re.DOTALL)
    m = pat.search(text)
    if not m:
        return [], []
    bucket_rows: list[dict] = []
    total_rows: list[dict] = []
    line_re = re.compile(
        r"^\s*(?P<label>.+?)\s+"
        r"(?P<pages>\d+)\s+"
        r"(?P<page_mb>[0-9.]+)\s+"
        r"(?P<live_mb>[0-9.]+)\s+"
        r"(?P<free_mb>[0-9.]+)\s+"
        r"(?P<garb_mb>[0-9.]+)\s+"
        r"(?P<live_pct>[0-9.]+)%\s+"
        r"(?P<free_pct>[0-9.]+)%\s+"
        r"(?P<garb_pct>[0-9.]+)%"
    )
    MB = 1024.0 * 1024.0
    for line in m.group("body").splitlines():
        if "per-major avg" in line:
            continue
        m2 = line_re.match(line)
        if not m2:
            continue
        d = m2.groupdict()
        row = {
            "label": d["label"].strip(),
            "pages": int(d["pages"]),
            "page_bytes": int(round(float(d["page_mb"]) * MB)),
            "live_bytes": int(round(float(d["live_mb"]) * MB)),
            "free_bytes": int(round(float(d["free_mb"]) * MB)),
            "garbage_bytes": int(round(float(d["garb_mb"]) * MB)),
            "live_pct": float(d["live_pct"]),
            "free_pct": float(d["free_pct"]),
            "garb_pct": float(d["garb_pct"]),
        }
        if row["label"] == "total":
            row["kind"] = "total"
            total_rows.append(row)
        elif row["label"] == "pinned":
            row["kind"] = "pinned"
            total_rows.append(row)
        else:
            row["kind"] = "bucket"
            bucket_rows.append(row)
    return bucket_rows, total_rows


def parse_freelist_histogram(text: str, header_substr: str) -> list[dict]:
    """Parses one free-list size-class histogram block. Returns one row per
    size class plus 'large-blk' (when present) and 'total' rows."""
    pat = re.compile(
        rf"Old-Gen Free-List Size-Class Histogram \({re.escape(header_substr)}[^)]*\):\n"
        r".*?cell_size.*?\n(?P<body>(?:.*\n)+?)(?:\n|\Z)",
        re.DOTALL)
    m = pat.search(text)
    if not m:
        return []
    rows = []
    line_re = re.compile(
        r"^\s*(?P<label>.+?)\s+"
        r"(?P<cells>\d+)\s+"
        r"(?P<bytes>\d+)\s+"
        r"(?P<bytes_mb>[0-9.]+)\s+"
        r"(?P<pct>[0-9.]+)%"
    )
    for line in m.group("body").splitlines():
        if "per-major avg" in line:
            continue
        m2 = line_re.match(line)
        if not m2:
            continue
        d = m2.groupdict()
        rows.append({
            "label": d["label"].strip(),
            "cells": int(d["cells"]),
            "bytes": int(d["bytes"]),
            "percent_bytes": float(d["pct"]),
        })
    return rows


# ---------------------------------------------------------------------------
# Per-variant run
# ---------------------------------------------------------------------------

def _pump(src, dests: list) -> None:
    """Forward bytes from `src` to every dest as soon as they arrive.
    `read1` returns whatever the kernel has buffered without waiting to fill
    a 4 KiB block, so each line the child emits surfaces immediately."""
    while True:
        chunk = src.read1(4096)
        if not chunk:
            return
        for d in dests:
            d.write(chunk)
            d.flush()


def _run_capturing(cmd, *, cwd, env, out_path: Path, err_path: Path,
                   tee: bool) -> int:
    """Run `cmd`, writing stdout/stderr to the given log files. When `tee` is
    set, the output is also forwarded live to the parent's stdout/stderr.

    Two reliability tweaks:

    * The child is force-line-buffered via `stdbuf -oL -eL`. Without this, glibc
      switches stdio to block-buffered mode whenever stdout is a pipe (which is
      exactly the case under tee), and you see no output until 4 KiB have
      accumulated or the process exits.
    * The child runs in its own process group (`start_new_session=True`) so a
      Ctrl+C in the parent doesn't double-fire on the child. We translate
      KeyboardInterrupt into SIGTERM-to-the-process-group, which lets
      eco-compiler's SIGTERM handler print GC stats before exiting; we then
      drain its stdout/stderr (which carries those stats) before re-raising.
    """
    line_buffered_cmd = ["stdbuf", "-oL", "-eL", *cmd]

    if not tee:
        with out_path.open("wb") as out, err_path.open("wb") as err:
            proc = subprocess.Popen(line_buffered_cmd, cwd=cwd, env=env,
                                    stdout=out, stderr=err,
                                    start_new_session=True)
            try:
                return proc.wait()
            except KeyboardInterrupt:
                _shutdown_child(proc)
                raise

    with out_path.open("wb") as out_f, err_path.open("wb") as err_f:
        proc = subprocess.Popen(line_buffered_cmd, cwd=cwd, env=env,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                start_new_session=True)
        t_out = threading.Thread(
            target=_pump, args=(proc.stdout, [out_f, sys.stdout.buffer]))
        t_err = threading.Thread(
            target=_pump, args=(proc.stderr, [err_f, sys.stderr.buffer]))
        t_out.start()
        t_err.start()
        try:
            rc = proc.wait()
        except KeyboardInterrupt:
            _shutdown_child(proc)
            t_out.join()
            t_err.join()
            raise
        t_out.join()
        t_err.join()
        return rc


_SHUTDOWN_GRACE_S = 15


def _shutdown_child(proc: subprocess.Popen) -> None:
    """Translate a Ctrl+C in the parent into a graceful shutdown of the child:

    1. SIGTERM the timeout(1) wrapper's process group. timeout(1) forwards
       SIGTERM to eco-compiler, whose SIGTERM handler in eco_entry.cpp
       writes the `[gc-stats] SIGTERM — printing GC statistics` marker and
       then prints the full GC-stats block to stdout.
    2. Wait up to _SHUTDOWN_GRACE_S seconds for the wrapper to exit. The
       grace window is generous because eco-compiler's stats handler is
       not async-signal-safe — if SIGTERM lands during a critical section
       (e.g. mid-allocation), getCombinedStats() may take a while to clear.
    3. If still alive, SIGKILL as a last resort.
    """
    print("\n[heap-profile] Ctrl+C — sending SIGTERM to eco-compiler "
          "(GC stats will follow)...", flush=True)
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=_SHUTDOWN_GRACE_S)
    except subprocess.TimeoutExpired:
        print(f"[heap-profile] eco-compiler did not exit within "
              f"{_SHUTDOWN_GRACE_S}s — sending SIGKILL", flush=True)
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def run_variant(*, name: str, change: str, heap_config: dict,
                variant_dir: Path, wall_seconds: int, tee: bool,
                heap_trace: bool) -> dict:
    """Runs the binary once and writes all per-variant TSVs. Returns the
    summary row (a dict keyed by SUMMARY_COLUMNS)."""
    variant_dir.mkdir(parents=True, exist_ok=True)
    cfg_path = variant_dir / "heap-config.json"
    cfg_path.write_text(json.dumps(heap_config, indent=2) + "\n")

    out_path = variant_dir / "stdout.log"
    err_path = variant_dir / "stderr.log"

    boot_mlir = BUILD_KERNEL / "bin" / "eco-compiler-boot.mlir"
    if boot_mlir.exists():
        boot_mlir.unlink()

    env = os.environ | {
        "ECO_HEAP_CONFIG": str(cfg_path),
        "ECO_HEAP_TRACE": "1" if heap_trace else "0",
        "ECO_GC_PHASE_PROFILE": "1",
    }
    cmd = [
        "/usr/bin/timeout", f"--kill-after={KILL_AFTER_S}s", str(wall_seconds),
        str(ECO_COMPILER), "make",
        "--optimize",
        "--kernel-package", "eco/compiler",
        "--local-package", f"eco/kernel={REPO_ROOT}/eco-kernel-cpp",
        "--output=bin/eco-compiler-boot.mlir",
        str(ELM_ENTRY),
    ]

    print(f"\n=== {name}  ({change}) — wall_seconds={wall_seconds} ===",
          flush=True)
    t0 = time.time()
    rc = _run_capturing(cmd, cwd=BUILD_KERNEL, env=env,
                        out_path=out_path, err_path=err_path, tee=tee)
    elapsed = time.time() - t0
    out_text = out_path.read_text(errors="replace")
    err_text = err_path.read_text(errors="replace")

    wall_s = float(wall_seconds) if rc == 124 else elapsed

    summary = parse_summary(out_text, err_text, wall_s)
    summary["name"] = name
    summary["change"] = change

    gc_timing_cols = ["wall_s", "major_s", "minor_s",
                      "helper_min_s", "helper_mut_s", "helper_s",
                      "mutator_s", "mutator_pct"]
    write_tsv(variant_dir / "gc_timing.tsv", gc_timing_cols,
              [{c: summary[c] for c in gc_timing_cols}])

    nursery_rows = parse_alloc_histogram(
        out_text, "Nursery Allocation Size Histogram")
    oldgen_rows = parse_alloc_histogram(
        out_text, "Old-Gen Allocation Size Histogram")
    write_tsv(variant_dir / "alloc_size_nursery.tsv",
              ["bucket", "count", "percent"], nursery_rows)
    write_tsv(variant_dir / "alloc_size_oldgen.tsv",
              ["bucket", "count", "percent"], oldgen_rows)

    resid_cols = ["kind", "label", "pages", "page_bytes", "live_bytes",
                  "free_bytes", "garbage_bytes",
                  "live_pct", "free_pct", "garb_pct"]
    cum_buckets, cum_totals = parse_residency_histogram(
        out_text, "cumulative")
    latest_buckets, latest_totals = parse_residency_histogram(
        out_text, "latest: most recent major-GC end")
    write_tsv(variant_dir / "residency_cumulative.tsv", resid_cols,
              cum_buckets + cum_totals)
    write_tsv(variant_dir / "residency_latest.tsv", resid_cols,
              latest_buckets + latest_totals)

    fl_cols = ["label", "cells", "bytes", "percent_bytes"]
    write_tsv(variant_dir / "freelist_cumulative.tsv", fl_cols,
              parse_freelist_histogram(out_text, "cumulative"))
    write_tsv(variant_dir / "freelist_latest.tsv", fl_cols,
              parse_freelist_histogram(
                  out_text, "latest: most recent major-GC end"))

    write_tsv(variant_dir / "summary.tsv", SUMMARY_COLUMNS, [summary])
    print(f"rc={rc}  wall={wall_s:.1f}s  major={summary['major_s']}s  "
          f"minor={summary['minor_s']}s  mutator%={summary['mutator_pct']}",
          flush=True)
    return summary


# ---------------------------------------------------------------------------
# Report writing
# ---------------------------------------------------------------------------

def write_report(group_dir: Path, *, mode: str, machine: str, ts: str,
                 wall_seconds: int, command_line: list[str],
                 summary_rows: list[dict]) -> None:
    md = []
    md.append(f"# heap-profile {mode} report")
    md.append("")
    md.append(f"- machine: `{machine}`")
    md.append(f"- timestamp: `{ts}` (UTC)")
    md.append(f"- wall_seconds: `{wall_seconds}`")
    md.append(f"- command: `{' '.join(command_line)}`")
    md.append("")
    md.append("## Summary")
    md.append("")
    md.append("| name | change | wall_s | major_s | minor_s | helper_s | "
              "mutator_s | mutator% | alloc_MB | peak_MB | final_live_MB | "
              "details |")
    md.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|")
    for r in summary_rows:
        rel = f"variants/{r['name']}"
        md.append(
            f"| {r['name']} | {r['change']} | {r['wall_s']} | {r['major_s']} | "
            f"{r['minor_s']} | {r['helper_s']} | {r['mutator_s']} | "
            f"{r['mutator_pct']} | {r['bytes_alloc_MB']} | "
            f"{r['peak_commit_MB']} | {r['final_live_MB']} | "
            f"[summary]({rel}/summary.tsv) "
            f"· [residency latest]({rel}/residency_latest.tsv) "
            f"· [freelist latest]({rel}/freelist_latest.tsv) |")
    md.append("")
    md.append("## Variants")
    md.append("")
    for r in summary_rows:
        rel = f"variants/{r['name']}"
        md.append(f"### {r['name']} — {r['change']}")
        md.append("")
        md.append(f"- wall: {r['wall_s']} s · major: {r['major_s']} s · "
                  f"minor: {r['minor_s']} s · helper: {r['helper_s']} s · "
                  f"mutator: {r['mutator_s']} s ({r['mutator_pct']}%)")
        md.append(f"- alloc: {r['bytes_alloc_MB']} MB · "
                  f"peak commit: {r['peak_commit_MB']} MB · "
                  f"final live: {r['final_live_MB']} MB")
        md.append("- files:")
        for fname in ("heap-config.json", "stdout.log", "stderr.log",
                      "summary.tsv", "gc_timing.tsv",
                      "alloc_size_nursery.tsv", "alloc_size_oldgen.tsv",
                      "residency_cumulative.tsv", "residency_latest.tsv",
                      "freelist_cumulative.tsv", "freelist_latest.tsv"):
            md.append(f"  - [`{fname}`]({rel}/{fname})")
        md.append("")
    md.append("## Files")
    md.append("")
    md.append("- [`runs.tsv`](runs.tsv) — combined per-variant summary "
              "(also the resume marker)")
    md.append("- [`args.json`](args.json) — CLI arguments + rebuild outcome")
    md.append("")
    md.append("All `.tsv` files use `\\t` as the field separator.")
    md.append("")
    (group_dir / "report.md").write_text("\n".join(md))


# ---------------------------------------------------------------------------
# Top-level driver
# ---------------------------------------------------------------------------

def make_group_dir(results_root: Path, machine: str, mode: str,
                   label: str | None,
                   resume_dir: Path | None) -> tuple[Path, str]:
    if resume_dir is not None:
        if not resume_dir.exists():
            sys.exit(f"ERROR: --resume-dir {resume_dir} does not exist")
        ts = resume_dir.name.split("__", 1)[0]
        return resume_dir, ts
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    suffix = label if label else (
        "sweep" if mode == "sweep" else "run-default")
    group_dir = results_root / machine / f"{ts}__{suffix}"
    group_dir.mkdir(parents=True, exist_ok=True)
    return group_dir, ts


def previously_done_names(group_dir: Path) -> set[str]:
    runs_tsv = group_dir / "runs.tsv"
    if not runs_tsv.exists():
        return set()
    done = set()
    with runs_tsv.open() as f:
        header = f.readline().rstrip("\n").split("\t")
        if "name" not in header:
            return set()
        idx = header.index("name")
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if idx < len(cols):
                done.add(cols[idx])
    return done


def cmd_run(args, machine: str, results_root: Path) -> None:
    rebuild = ensure_binaries_fresh(args.skip_rebuild)
    cfg_path = Path(args.config or DEFAULT_HEAP_CONFIG)
    if not cfg_path.exists():
        sys.exit(f"ERROR: heap config {cfg_path} does not exist")
    heap_config = json.loads(cfg_path.read_text())

    group_dir, ts = make_group_dir(results_root, machine, "run",
                                   args.label, args.resume_dir)
    name = args.label or "default"
    variant_dir = group_dir / "variants" / name

    done = previously_done_names(group_dir)
    if name in done:
        print(f"SKIP {name} (already in {group_dir / 'runs.tsv'})", flush=True)
        return

    summary = run_variant(
        name=name, change=f"config={cfg_path.name}",
        heap_config=heap_config,
        variant_dir=variant_dir, wall_seconds=args.wall_seconds,
        tee=args.tee, heap_trace=args.heap_trace)

    append_tsv_row(group_dir / "runs.tsv", SUMMARY_COLUMNS, summary)
    (group_dir / "args.json").write_text(json.dumps({
        "argv": sys.argv,
        "machine": machine,
        "results_root": str(results_root),
        "timestamp_utc": ts,
        "wall_seconds": args.wall_seconds,
        "config": str(cfg_path),
        "rebuild": rebuild,
    }, indent=2))
    write_report(group_dir, mode="run", machine=machine, ts=ts,
                 wall_seconds=args.wall_seconds,
                 command_line=sys.argv,
                 summary_rows=[summary])
    print(f"\nReport: {group_dir / 'report.md'}", flush=True)


def cmd_sweep(args, machine: str, results_root: Path) -> None:
    rebuild = ensure_binaries_fresh(args.skip_rebuild)
    selected = None
    if args.variants:
        selected = set(s.strip() for s in args.variants.split(",") if s.strip())
    variants = (load_variants_file(args.variants_file)
                if args.variants_file else VARIANTS)
    group_dir, ts = make_group_dir(results_root, machine, "sweep",
                                   args.label, args.resume_dir)
    done = previously_done_names(group_dir)

    summary_rows: list[dict] = []
    if (group_dir / "runs.tsv").exists():
        with (group_dir / "runs.tsv").open() as f:
            cols = f.readline().rstrip("\n").split("\t")
            for line in f:
                cells = line.rstrip("\n").split("\t")
                summary_rows.append(dict(zip(cols, cells)))

    for name, change, overrides in variants:
        if selected is not None and name not in selected:
            continue
        if name in done:
            print(f"SKIP {name} (already in runs.tsv)", flush=True)
            continue
        heap_config = BASELINE_HEAP | overrides
        variant_dir = group_dir / "variants" / name
        summary = run_variant(
            name=name, change=change, heap_config=heap_config,
            variant_dir=variant_dir, wall_seconds=args.wall_seconds,
            tee=args.tee, heap_trace=args.heap_trace)
        append_tsv_row(group_dir / "runs.tsv", SUMMARY_COLUMNS, summary)
        summary_rows.append(summary)

    (group_dir / "args.json").write_text(json.dumps({
        "argv": sys.argv,
        "machine": machine,
        "results_root": str(results_root),
        "timestamp_utc": ts,
        "wall_seconds": args.wall_seconds,
        "variants_file": str(args.variants_file) if args.variants_file else None,
        "variants_filter": sorted(selected) if selected else None,
        "rebuild": rebuild,
    }, indent=2))
    write_report(group_dir, mode="sweep", machine=machine, ts=ts,
                 wall_seconds=args.wall_seconds,
                 command_line=sys.argv,
                 summary_rows=summary_rows)
    print(f"\nReport: {group_dir / 'report.md'}", flush=True)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="heap-profile.py",
        description="Single-run + sweep heap profiler for the Eco runtime.")
    p.add_argument("--machine", help="machine name override")
    p.add_argument("--results-root",
                   help="base directory for results (overrides local config)")
    p.add_argument("--no-prompt", action="store_true",
                   help="fail if local config is missing instead of prompting")
    p.add_argument("--skip-rebuild", action="store_true",
                   help="skip the build-freshness check")
    p.add_argument("--tee", action="store_true",
                   help="also stream eco-compiler stdout/stderr to the "
                        "console (logs are still written to the variant dir)")
    p.add_argument("--heap-trace", action="store_true",
                   help="enable ECO_HEAP_TRACE in the runtime. Off by "
                        "default; the peak_commit_MB and final_live_MB "
                        "summary columns require this and will read as 0 "
                        "when disabled.")
    p.add_argument("--list-variants", action="store_true",
                   help="print the sweep variants table and exit")

    sub = p.add_subparsers(dest="cmd", required=False)

    pr = sub.add_parser("run", help="single run with one heap config")
    pr.add_argument("--config", help=f"heap config JSON "
                    f"(default {DEFAULT_HEAP_CONFIG})")
    pr.add_argument("--label", help="folder label (default: 'default')")
    pr.add_argument("--wall-seconds", type=int, default=DEFAULT_WALL_SECONDS,
                    help=f"per-run wall budget (default {DEFAULT_WALL_SECONDS})")
    pr.add_argument("--resume-dir", type=Path,
                    help="reuse an existing run-group directory")
    pr.add_argument("--dry-run", action="store_true",
                    help="print resolved paths and exit")

    ps = sub.add_parser("sweep", help="run the hard-coded variants matrix")
    ps.add_argument("--variants",
                    help="comma-separated subset of variant names")
    ps.add_argument("--variants-file", type=Path,
                    help="JSON file with a list of {name, change?, "
                         "overrides} objects, replacing the built-in matrix")
    ps.add_argument("--label", help="folder label (default: 'sweep')")
    ps.add_argument("--wall-seconds", type=int, default=DEFAULT_WALL_SECONDS,
                    help=f"per-run wall budget (default {DEFAULT_WALL_SECONDS})")
    ps.add_argument("--resume-dir", type=Path,
                    help="reuse an existing run-group directory")
    ps.add_argument("--dry-run", action="store_true",
                    help="print resolved paths and exit")
    return p


def main():
    parser = build_parser()
    args = parser.parse_args()
    if args.list_variants:
        for n, c, _ in VARIANTS:
            print(f"  {n:<12}  {c}")
        return
    if args.cmd is None:
        parser.error("a subcommand is required: run | sweep")

    machine, results_root = resolve_paths(args)

    if args.dry_run:
        print(json.dumps({
            "cmd": args.cmd,
            "machine": machine,
            "results_root": str(results_root),
            "wall_seconds": args.wall_seconds,
        }, indent=2))
        return

    if args.cmd == "run":
        cmd_run(args, machine, results_root)
    elif args.cmd == "sweep":
        cmd_sweep(args, machine, results_root)
    else:
        parser.error(f"unknown command {args.cmd!r}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        # The child has already been SIGTERMed and its GC stats drained by
        # _run_capturing's KeyboardInterrupt handler. Exit cleanly with the
        # standard 128+SIGINT code, no Python traceback.
        sys.exit(130)
