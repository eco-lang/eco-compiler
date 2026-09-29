#!/usr/bin/env python3
"""
Heap profiler for the Eco runtime.

Two modes:
  run    — compile Stage 7 once with one heap-config JSON.
  sweep  — compile Stage 7 once per entry of a VARIANTS matrix
           (the built-in one in this file, or a JSON file passed via
           `--variants-file`).

Runs go to completion unless `--wall-seconds` caps them.

Each invocation creates one timestamped folder under
    <results_root>/<machine>/<YYYY-MM-DDTHH-MM-SSZ>__<label>/
containing:
  - report.md                   Markdown summary (medians per cell)
  - runs.tsv                    one MEDIAN row per cell (resume marker)
  - runs_raw.tsv                every run: metrics, rc, signal, output hash,
                                validity (resumes a cell mid-way)
  - args.json                   CLI args, resolved paths, rebuild outcome
  - variants/<name>/            heap-config.json, summary.tsv, runs.tsv, and
                                r<N>/ per run: stdout.log (stats banner),
                                stderr.log, time.txt (GNU time -v), TSVs.

Each cell runs `--repeat` times (default 3), strictly serially, under GNU
`time -v`. Metrics: wall, CPU (user + sys), max RSS, pause p50/p90/p99/p99.9/
max and MMU (phase-timer builds: `--build-tree build-phasetimers`), promoted
and tenured bytes, old-gen peak, minors/majors, GC time, mutator and
collector CPU. A run counts only if it exits 0, takes no signal, and emits
output byte-identical to the sitting's first valid run.

`<results_root>` and `<machine>` come from `heap-profile.local.json` next to
this script (created on first run via interactive prompt) or from CLI flags.

All metric files are tab-separated (`.tsv`).
"""

import argparse
import hashlib
import json
import os
import re
import shutil
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
ECO_COMPILER = REPO_ROOT / "build/compiler/build-kernel/bin/eco-compiler"
ECO_BOOT_NATIVE = REPO_ROOT / "build/runtime/src/codegen/eco-boot-native"
ECO_COMPILER_MLIR = REPO_ROOT / "build/compiler/build-kernel/bin/eco-compiler.mlir"
# Cached object file from `eco-boot-native --emit=obj eco-compiler.mlir`.
# Lets the C++-only edit-test loop skip the heavy MLIR/LLVM lowering and only
# re-run the link step against freshly rebuilt runtime/kernel libraries.
ECO_COMPILER_OBJ = REPO_ROOT / "build/compiler/build-kernel/bin/eco-compiler.o"
BUILD_KERNEL = REPO_ROOT / "build/compiler/build-kernel"
ECO_BOOT_2_RUNNER = BUILD_KERNEL / "bin/eco-boot-2-runner.js"
ECO_KERNEL_CPP = REPO_ROOT / "eco-kernel-cpp"
ELM_ENTRY = REPO_ROOT / "compiler/src/Terminal/Main.elm"
COMPILER_SRC = REPO_ROOT / "compiler/src"
RUNTIME_SRC = REPO_ROOT / "runtime/src"
DEFAULT_HEAP_CONFIG = REPO_ROOT / "build/compiler/build-kernel/heap-config.json"
LOCAL_CONFIG = REPO_ROOT / "heap-profile.local.json"
ECO_STUFF = BUILD_KERNEL / "eco-stuff"

# The build tree whose runtime libraries the profiled compiler is LINKED
# against (`--build-tree`, default `build`). The object file is always lowered
# by the primary tree's eco-boot-native: lowering does not depend on the GC
# stats / phase-timer switches. It is then linked by the selected tree's
# eco-boot-native, which picks up that tree's own archives. With
# `--build-tree build-phasetimers` this is the "phase-timer relink" the
# threaded-GC experiments used: the same code, plus the pause log that the
# pause percentiles and MMU columns are parsed from.
PRIMARY_TREE = REPO_ROOT / "build"
BUILD_TREE = PRIMARY_TREE
ECO_BOOT_NATIVE_LINK = ECO_BOOT_NATIVE


# Set by `--compiler-mlir`: lower THIS file instead of the bootstrap product.
COMPILER_MLIR_OVERRIDE: Path | None = None


def select_build_tree(tree: str, compiler_mlir: str | None = None) -> None:
    """Point the link step (and the linked binary's name) at `tree`, and
    optionally the lowering input at `compiler_mlir`. Each (MLIR, tree) pair
    gets its own object and binary name, so switching either never reuses an
    artefact built from the other."""
    global BUILD_TREE, ECO_BOOT_NATIVE_LINK, ECO_COMPILER
    global ECO_COMPILER_MLIR, ECO_COMPILER_OBJ, COMPILER_MLIR_OVERRIDE
    BUILD_TREE = REPO_ROOT / tree
    ECO_BOOT_NATIVE_LINK = BUILD_TREE / "runtime/src/codegen/eco-boot-native"
    stem = "eco-compiler"
    if compiler_mlir is not None:
        COMPILER_MLIR_OVERRIDE = Path(compiler_mlir).resolve()
        ECO_COMPILER_MLIR = COMPILER_MLIR_OVERRIDE
        # Cached next to the bootstrap artefacts, named after the MLIR, so an
        # existing `<stem>.o` from earlier experiments is reused as-is.
        ECO_COMPILER_OBJ = BUILD_KERNEL / "bin" / f"{COMPILER_MLIR_OVERRIDE.stem}.o"
        stem = f"eco-compiler-{COMPILER_MLIR_OVERRIDE.stem}"
    if BUILD_TREE != PRIMARY_TREE:
        stem = f"{stem}-{BUILD_TREE.name}"
    ECO_COMPILER = BUILD_KERNEL / "bin" / stem


# `timeout(1)` arguments, used ONLY when --wall-seconds is given. The default
# is no budget at all: a run goes to completion. The 60 s sampling window this
# script was born with predates the compiler being able to finish a self-compile
# at all; today it finishes in ~4 minutes, and a truncated run sees too few
# major GCs to say anything about old-gen tuning.
KILL_AFTER_S = 10

# ---------------------------------------------------------------------------
# Variants (hard-coded for sweep mode)
# ---------------------------------------------------------------------------

# An exact mirror of the compiled-in HeapConfig defaults in
# runtime/src/allocator/AllocatorCommon.hpp — all 88 keys the ECO_HEAP_CONFIG
# parser accepts (HeapConfigJson.cpp kKnownKeys), at the value the runtime uses
# when no ECO_HEAP_CONFIG is set. Grouped as in docs/options.md.
#
# Keeping this a COMPLETE mirror is what makes the `baseline` sweep cell the
# shipped configuration: a field omitted here would silently fall back to the
# struct default, so a drift between the two could not be seen in the results.
# `compiler/cmake/bootstrap/build-kernel/heap-config.json` (copied into the
# build tree at CMake configure time) carries the same 88 values. Both were
# generated from a default-constructed HeapConfig and checked to round-trip
# through applyHeapConfigJsonFile field for field (2026-09-28; regenerated
# 2026-09-29 for the retuned defaults). Regenerate
# them whenever a default in AllocatorCommon.hpp changes or a key is added.
#
# "auto" values are written as the auto sentinel, not the resolved number:
# thread counts 0 (min(cap, available CPUs)), nursery_regions 2, and
# nursery_region_eden_flip -1, so the baseline resolves exactly as the
# shipped binary does on the machine it runs on.
BASELINE_HEAP = {
    # Heap-wide and large-object placement.
    "max_heap_size":                     "24G",
    "nursery_region_bytes":              0,
    "alloc_buffer_size":                 "512K",
    "large_object_threshold":            "8K",
    "large_ptr_nursery_divisor":         8,
    "large_ptr_nursery_max_size":        "128K",
    # String / rope heuristics (not GC, same file).
    "string_flatten_limit":              "128K",
    "string_tiny_slice_limit":           128,
    "utf8_view_min_len":                 32,
    "utf8_strings_enabled":              True,
    "rope_max_height":                   32,
    "rope_leaf_count_limit":             64,
    "rope_min_leaf_size":                128,
    # Nursery and minor GC (parallel minor: TG6).
    "nursery_block_count":               256,
    "nursery_max_block_count":           384,
    "nursery_gc_threshold":              0.95,
    "nursery_growth_threshold":          0.2,
    "promotion_age":                     1,
    "use_hybrid_dfs":                    True,
    "gc_minor_threads":                  0,
    "gc_minor_threads_cap":              8,
    "minor_lab_bytes":                   "8K",
    "minor_parallel_min_bytes":          "4M",
    "minor_prefetch_children":           True,
    "minor_fifo_order":                  False,
    # Region nursery and concurrent tenuring (TG7). nursery_regions 2 = auto (resolves to 1);
    # nursery_region_eden_flip -1 = on only in ECO_HEAP_VALIDATE builds.
    "nursery_regions":                   2,
    "nursery_region_eden_flip":          -1,
    "tenure_mode":                       2,
    "tenure_sync_threads":               1,
    "tenure_help":                       1,
    "tenure_help_threads":               0,
    "tenure_priority":                   0,
    "heal_parallel_min":                 65536,
    "shadow_granule_log2":               4,
    "tenure_collector_threads":          1,
    "tenure_fifo_order":                 False,
    # Old generation and major-GC triggers (LiveBudget / demote: TG2; headroom: TG5c).
    "initial_old_gen_size":              "16M",
    "major_gc_initiating_occupancy":     0.95,
    "major_gc_global_pressure_fraction": 0.85,
    "major_gc_target_utilization":       0.5,
    "major_gc_garbage_fraction":         0.7,
    "major_gc_live_budget":              4.5,
    "live_growth_bound":                 1.5,
    "major_gc_live_budget_paced":        True,
    "major_gc_headroom_margin":          1.5,
    "major_gc_garbage_backstop":         0.0,
    "garbage_denom_cap":                 0.0,
    "demote_live_fraction":              0.3,
    "old_gen_bitmap_alloc":              True,
    # Marking: incremental (TG5a), parallel (TG5b), concurrent (TG5c). Thread counts 0 = auto
    # (min(cap, available CPUs)).
    "incremental_mark":                  True,
    "incremental_mark_slices":           32,
    "incremental_mark_min_slice_units":  16384,
    "incremental_mark_predict_growth":   1.25,
    "incremental_mark_finish_fraction":  0.95,
    "gc_mark_threads":                   0,
    "gc_mark_threads_cap":               16,
    "conc_mark":                         2,
    "conc_mark_threads":                 0,
    "conc_mark_threads_cap":             4,
    "conc_mark_priority":                0,
    "conc_mark_assist_lag":              8,
    # Helper thread, deferred decommit, commit-ahead (TG3). decommit_delay_syncs 4294967295 = never.
    "decommit_on_oldgen_release":        True,
    "gc_thread_mode":                    2,
    "gc_helper_threads":                 1,
    "gc_helper_cpu":                     -1,
    "decommit_delay_syncs":              4294967295,
    "decommit_pending_max_bytes":        0,
    "decommit_delay_majors":             1,
    "commit_ahead_bytes":                "128M",
    # Small-class page budgeting.
    "small_class_heap_budget_bytes":     "1G",
    "small_class_cell_max_bytes":        "8K",
    # Old-gen sweep pacing. mark_work_ratio has no effect (kept so old files parse).
    "sweep_work_budget":                 "4K",
    "minor_sweep_divisor":               1,
    "initial_sweep_budget":              "64K",
    "mark_work_ratio":                   2,
    "sweep_bytes_per_alloc_byte":        2.0,
    "max_sweep_bytes_per_alloc":         "1M",
    "max_sweep_bytes_hard":              "4M",
    "sweep_cap_ratio_low":               0.5,
    "sweep_cap_ratio_medium":            0.75,
    "sweep_cap_ratio_high":              0.9,
    "sweep_scale_low":                   1.0,
    "sweep_scale_medium":                2.0,
    "sweep_scale_high":                  4.0,
    "sweep_scale_crit":                  8.0,
    "sweep_unswept_ratio_boost":         0.5,
    "sweep_unswept_scale":               2.0,
    "panic_sweep_slice_bytes":           "1M",
}

VARIANTS = [
    ("baseline",     "(defaults)",                     {}),
    # A. Nursery sizing
    ("A_nb16",       "nursery_block_count=16",         {"nursery_block_count": 16}),
    ("A_nb32",       "nursery_block_count=32",         {"nursery_block_count": 32}),
    ("A_nb128",      "nursery_block_count=128",        {"nursery_block_count": 128}),
    # B. Promotion age
    ("B_age2",       "promotion_age=2",                {"promotion_age": 2}),
    ("B_age3",       "promotion_age=3",                {"promotion_age": 3}),
    # C. Major GC trigger / shrink
    ("C1_early",     "init=0.50 target=0.30",          {"major_gc_initiating_occupancy": 0.50, "major_gc_target_utilization": 0.30}),
    ("C2_mio085",    "init=0.85 (default 0.95)",       {"major_gc_initiating_occupancy": 0.85}),
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

# Per-run metrics. Units are in the names. A metric the binary does not print
# (pause percentiles and MMU need an ECO_GC_PHASE_TIMERS build; the region,
# concurrent-mark and mutator-CPU lines need those engines active) is written
# as an EMPTY cell, never 0, so a missing number cannot pass for a measurement
# and medians skip it.
METRIC_COLUMNS = [
    # GNU `time -v` (whole process tree).
    "wall_s", "cpu_s", "user_s", "sys_s", "max_rss_GB",
    # Pause log (phase-timer builds only).
    "pause_n", "pause_total_s",
    "pause_p50_ms", "pause_p90_ms", "pause_p99_ms", "pause_p999_ms",
    "pause_max_ms", "minor_pause_max_ms",
    "mmu_100ms_pct", "mmu_200ms_pct", "mmu_500ms_pct",
    # Promotion and old-gen memory.
    "promoted_MiB", "objs_promoted", "tenured_MB", "oldgen_peak_MB",
    # Collection counts and in-pause GC time.
    "minor_gcs", "major_gcs", "gc_total_s", "major_s", "minor_s",
    "helper_s", "nursery_alloc_s",
    # Thread CPU. The mutator figure comes from the runtime's own CPU clock:
    # with concurrent marking and tenuring, "wall - GC" is no longer mutator
    # time, so that derived column was dropped.
    "mutator_cpu_s", "mutator_cpu_out_s", "conc_mark_cpu_s",
    "collector_cpu_s", "late_minors",
    # Allocation.
    "bytes_alloc_MB", "objs_alloc", "peak_commit_MB", "final_live_MB",
    "registry_ms",
]

# One row per run (runs_raw.tsv, variants/<name>/runs.tsv).
RAW_COLUMNS = ["name", "rep", "change", *METRIC_COLUMNS,
               "rc", "signal", "out_bytes", "out_md5", "valid"]

# One row per cell: the MEDIAN of each metric over the cell's valid runs
# (runs.tsv, variants/<name>/summary.tsv). runs.tsv is also the resume marker.
SUMMARY_COLUMNS = ["name", "change", "runs", "valid_runs", *METRIC_COLUMNS,
                   "out_md5"]


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
    results_root = Path(args.results_root or cfg.get("results_root")).resolve()
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


def _emit_eco_compiler_obj() -> None:
    """Lower eco-compiler.mlir to a cached object file (Stage 6 minus the
    link). The MLIR pipeline + LLVM IR + RS4GC + object emission run here;
    the link step is deferred to `_link_eco_compiler_obj`. Splitting the two
    lets a C++-only edit re-run only the cheap second half."""
    if not ECO_COMPILER_MLIR.exists():
        sys.exit(f"ERROR: {ECO_COMPILER_MLIR} not found; cannot emit object "
                 "file. Run Stage 5 first.")
    print(f"[heap-profile] emitting {ECO_COMPILER_OBJ.name} from "
          f"{ECO_COMPILER_MLIR.name} (eco-boot-native --emit=obj)...",
          flush=True)
    subprocess.run(
        [str(ECO_BOOT_NATIVE), "--emit=obj",
         str(ECO_COMPILER_MLIR), "-o", str(ECO_COMPILER_OBJ)],
        cwd=REPO_ROOT, check=True)


def _link_eco_compiler_obj() -> None:
    """Link the cached eco-compiler.o + freshly-rebuilt runtime/kernel
    static libraries into the eco-compiler ELF. Stage 6's link step in
    isolation. eco-boot-native recognises a .o input and skips the MLIR/LLVM
    pipeline, going straight to its `linkExecutable` driver."""
    if not ECO_COMPILER_OBJ.exists():
        sys.exit(f"ERROR: {ECO_COMPILER_OBJ} not found; cannot relink "
                 "eco-compiler. Run --emit=obj first.")
    print(f"[heap-profile] linking {ECO_COMPILER.name} from "
          f"{ECO_COMPILER_OBJ.name} against {BUILD_TREE.name}/ archives "
          f"(eco-boot-native link-only)...",
          flush=True)
    subprocess.run(
        [str(ECO_BOOT_NATIVE_LINK), str(ECO_COMPILER_OBJ),
         "-o", str(ECO_COMPILER)],
        cwd=REPO_ROOT, check=True)


# Bootstrap stages 2+ self-compile through Node and need a 12 GB heap.
# bootstrap.md prescribes this exact value.
_BOOTSTRAP_NODE_OPTIONS = "--max-old-space-size=12000"


def _bootstrap_env() -> dict:
    """Environment for Node-driven bootstrap stages. Inherits the parent's env
    and overrides NODE_OPTIONS — the user's existing setting is replaced (not
    merged with) so a too-small `--max-old-space-size` value upstream cannot
    silently OOM the self-compile."""
    return os.environ | {"NODE_OPTIONS": _BOOTSTRAP_NODE_OPTIONS}


def _full_bootstrap_to_stage6() -> None:
    """Wipe `compiler/build-kernel/bin/` and walk bootstrap.md Stages 1-6,
    ending with a freshly linked `eco-compiler` ELF.

    Stages 2-5 read intermediate artefacts (`eco-boot.js`, `eco-boot-2.js`,
    `eco-boot-2-runner.js`) from `build-kernel/bin/`; if Elm sources have
    moved on, those artefacts compile against stale code, so we wipe the
    folder and regenerate everything from Stage 1. The Elm dependency cache
    in `build-kernel/eco-stuff/` is preserved — only typed-object (.ecot)
    files are scrubbed before Stage 5, since JS-output stages don't
    invalidate them and leftovers crash monomorphization."""
    bin_dir = BUILD_KERNEL / "bin"
    print(f"[heap-profile] Elm sources newer than {ECO_COMPILER_MLIR.name} — "
          f"clearing {bin_dir} and running bootstrap Stages 1-6...",
          flush=True)
    if bin_dir.exists():
        shutil.rmtree(bin_dir)
    bin_dir.mkdir(parents=True, exist_ok=True)

    compiler_dir = REPO_ROOT / "compiler"
    env = _bootstrap_env()

    print("[heap-profile] Stage 1: stock Elm → build-xhr/bin/guida.js",
          flush=True)
    subprocess.run(["./scripts/build.sh", "bin"],
                   cwd=compiler_dir, env=env, check=True)

    print("[heap-profile] Stage 2: guida.js → build-kernel/bin/eco-boot.js",
          flush=True)
    subprocess.run(["./scripts/build-self.sh", "bin"],
                   cwd=compiler_dir, env=env, check=True)

    print("[heap-profile] Stages 3+4: fixed-point verification "
          "(eco-boot-2.js, eco-boot-3.js)", flush=True)
    subprocess.run(["./scripts/build-verify.sh"],
                   cwd=compiler_dir, env=env, check=True)

    eco_stuff = BUILD_KERNEL / "eco-stuff"
    if eco_stuff.exists():
        for ecot in eco_stuff.rglob("*.ecot"):
            try:
                ecot.unlink()
            except FileNotFoundError:
                continue

    print(f"[heap-profile] Stage 5: eco-boot-2 → {ECO_COMPILER_MLIR.name}",
          flush=True)
    if not ECO_BOOT_2_RUNNER.exists():
        sys.exit(f"ERROR: {ECO_BOOT_2_RUNNER} not found after Stages 3+4; "
                 "build-verify.sh did not produce the runner.")
    subprocess.run(
        ["node", "--stack-size=65536", str(ECO_BOOT_2_RUNNER), "make",
         "--optimize",
         "--kernel-package", "eco/compiler",
         "--local-package", f"eco/kernel={ECO_KERNEL_CPP}",
         f"--output=bin/{ECO_COMPILER_MLIR.name}",
         str(ELM_ENTRY)],
        cwd=BUILD_KERNEL, env=env, check=True)

    print("[heap-profile] Stage 6: eco-boot-native lowers .mlir to "
          f"{ECO_COMPILER_OBJ.name}, then links to eco-compiler ELF",
          flush=True)
    _emit_eco_compiler_obj()
    _link_eco_compiler_obj()


def _newest_archive_mtime(tree: Path) -> float:
    """Newest static archive the link step pulls from `tree`."""
    newest = 0.0
    for sub in ("runtime", "elm-kernel-cpp", "eco-kernel-cpp"):
        root = tree / sub
        if root.is_dir():
            for a in root.rglob("*.a"):
                newest = max(newest, a.stat().st_mtime)
    return newest


def ensure_binaries_fresh(skip: bool, allow_bootstrap: bool = False) -> dict:
    """Bring all build artefacts up to date in dependency order:

      1. `cmake --build` (ALL targets) on the primary tree and, if different,
         the selected `--build-tree`. Every runtime archive must be current,
         not just eco-boot-native: on 2026-09-28 a stale libEcoEntryStatic.a
         (old GCStats layout) linked into a candidate compiler printed a full
         banner and then SIGSEGV'd at exit. A no-op build costs a second.
      2. Without --compiler-mlir: if eco-compiler.mlir is missing or older
         than any compiler/src .elm source, stop — unless --bootstrap was
         given, in which case wipe `compiler/build-kernel/bin/` and run the
         full bootstrap (Stages 1-6 from guides/bootstrap.md).
      3. Refresh the cached eco-compiler.o (Stage 6 minus link) if it's
         missing or older than eco-compiler.mlir.
      4. Re-link the profiled compiler if it's missing or older than the .o
         cache, the linking eco-boot-native, or any archive in the selected
         tree. This is the fast path for C++-only edits: the heavy MLIR/LLVM
         lowering is reused from the cached .o, and only the link runs."""
    outcome = {"checked": True,
               "build_tree": BUILD_TREE.name,
               "compiler": str(ECO_COMPILER),
               "built_trees": [],
               "relinked_eco_compiler": False,
               "rebuilt_compiler_mlir": False,
               "rebuilt_compiler_obj": False,
               "ran_full_bootstrap": False,
               "skipped": False}
    if skip:
        outcome["checked"] = False
        outcome["skipped"] = True
        return outcome

    trees = [PRIMARY_TREE] + ([BUILD_TREE] if BUILD_TREE != PRIMARY_TREE else [])
    for tree in trees:
        if not (tree / "CMakeCache.txt").exists():
            sys.exit(f"ERROR: {tree} is not a configured build tree")
        print(f"[heap-profile] cmake --build {tree.name} (all targets)...",
              flush=True)
        subprocess.run(["cmake", "--build", str(tree)], cwd=REPO_ROOT,
                       check=True)
        outcome["built_trees"].append(tree.name)
    if not ECO_BOOT_NATIVE_LINK.exists():
        sys.exit(f"ERROR: {ECO_BOOT_NATIVE_LINK} not found after the build")

    if COMPILER_MLIR_OVERRIDE is not None:
        if not ECO_COMPILER_MLIR.exists():
            sys.exit(f"ERROR: --compiler-mlir {ECO_COMPILER_MLIR} not found")
        outcome["compiler_mlir"] = str(ECO_COMPILER_MLIR)
        outcome["compiler_mlir_md5"] = hashlib.md5(
            ECO_COMPILER_MLIR.read_bytes()).hexdigest()
        stale_mlir = False
    else:
        elm_mtime = _newest_mtime_under(COMPILER_SRC, (".elm",))
        stale_mlir = (not ECO_COMPILER_MLIR.exists()
                      or ECO_COMPILER_MLIR.stat().st_mtime < elm_mtime)
    if stale_mlir and not allow_bootstrap:
        # The bootstrap below DELETES build/compiler/build-kernel/bin/, which
        # also holds every experiment's snapshot binaries (46 GB on
        # 2026-09-28, including the baseline eco-optTA2). Never do that as a
        # side effect of starting a profile.
        sys.exit(f"ERROR: {ECO_COMPILER_MLIR} is missing or older than the "
                 f"Elm sources. Either pass --compiler-mlir <file> to profile "
                 f"an existing compiler MLIR (for the threaded-GC baseline: "
                 f"snapshots/lss-loop/keep-TA2/bin/ecoTG6base.mlir), or pass "
                 f"--bootstrap to WIPE {BUILD_KERNEL / 'bin'} and rebuild it "
                 f"through bootstrap Stages 1-6.")
    mlir_mtime = (ECO_COMPILER_MLIR.stat().st_mtime
                  if ECO_COMPILER_MLIR.exists() else 0.0)
    if stale_mlir:
        _full_bootstrap_to_stage6()
        outcome["ran_full_bootstrap"] = True
        outcome["rebuilt_compiler_mlir"] = True
        outcome["rebuilt_compiler_obj"] = True
        outcome["relinked_eco_compiler"] = True
        # Stage 6 links through _link_eco_compiler_obj, i.e. against the
        # selected tree already.
        return outcome

    obj_mtime = (ECO_COMPILER_OBJ.stat().st_mtime
                 if ECO_COMPILER_OBJ.exists() else 0.0)
    if not ECO_COMPILER_OBJ.exists() or obj_mtime < mlir_mtime:
        # First run on a checkout that predates the .o cache, or the
        # .mlir was regenerated outside of this script.
        _emit_eco_compiler_obj()
        outcome["rebuilt_compiler_obj"] = True
        obj_mtime = ECO_COMPILER_OBJ.stat().st_mtime

    link_inputs_mtime = max(ECO_BOOT_NATIVE_LINK.stat().st_mtime,
                            _newest_archive_mtime(BUILD_TREE), obj_mtime)
    compiler_mtime = ECO_COMPILER.stat().st_mtime if ECO_COMPILER.exists() else 0.0
    if not ECO_COMPILER.exists() or compiler_mtime < link_inputs_mtime:
        _link_eco_compiler_obj()
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


def _opt_float(text: str, pattern: str, flags=0) -> float | None:
    m = re.search(pattern, text, flags)
    return float(m.group(1)) if m else None


def _opt_int(text: str, pattern: str, flags=0) -> int | None:
    m = re.search(pattern, text, flags)
    return int(m.group(1)) if m else None


def _bytes_to_mib(value: float, unit: str) -> float:
    return value * {"B": 1.0 / 1048576, "KiB": 1.0 / 1024, "MiB": 1.0,
                    "GiB": 1024.0}[unit]


def _fmt(v, digits: int) -> str:
    """Empty for a metric the run did not print; fixed-point otherwise."""
    if v is None:
        return ""
    if isinstance(v, int):
        return str(v)
    return f"{v:.{digits}f}"


def parse_time_v(text: str) -> dict:
    """Parse GNU `time -v` output: CPU is user + sys of the whole process
    tree (every GC and helper thread included), RSS is the peak of any
    process in it."""
    wall = None
    m = re.search(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): (\S+)", text)
    if m:
        wall = 0.0
        for part in m.group(1).split(":"):
            wall = wall * 60 + float(part)
    user = _opt_float(text, r"User time \(seconds\): ([0-9.]+)")
    sys_ = _opt_float(text, r"System time \(seconds\): ([0-9.]+)")
    rss_kb = _opt_int(text, r"Maximum resident set size \(kbytes\): (\d+)")
    return {
        "time_wall_s": wall,
        "user_s": user,
        "sys_s": sys_,
        "cpu_s": (user + sys_) if user is not None and sys_ is not None else None,
        "max_rss_GB": rss_kb / 1e6 if rss_kb is not None else None,
    }


# `printPauseLine` in GCStats.cpp: label, n, total (s), p50/p90/p99/p99.9/max (ms).
_PAUSE_LINE_RE = (r"\s+n=(\d+)\s+total=([0-9.]+) s\s+p50=([0-9.]+) ms\s+"
                  r"p90=([0-9.]+) ms\s+p99=([0-9.]+) ms\s+p99\.9=([0-9.]+) ms\s+"
                  r"max=([0-9.]+) ms")


def parse_summary(out_text: str, err_text: str, wall_s: float,
                  time_v: dict) -> dict:
    major_gcs = _first_int(out_text, r"Major GC cycles:\s+(\d+)")
    minor_gcs = _first_int(out_text, r"Minor GC cycles:\s+(\d+)")
    bytes_mb = _first_float(out_text, r"Bytes allocated:\s+([0-9.]+)\s*MB")
    objs = _first_int(out_text, r"Objects allocated:\s+(\d+)")
    objs_promoted = _opt_int(out_text, r"Objects promoted:\s+(\d+)")
    major_s = _first_time_seconds(
        out_text, r"Major GC Timing:.*?Total time:\s+" + _TIME_RE)
    minor_s = _first_time_seconds(
        out_text, r"Minor GC Timing:.*?Total time:\s+" + _TIME_RE)
    m = re.search(r"Total GC/Alloc time:\s+" + _TIME_RE, out_text)
    gc_total_s = _t_to_s(float(m.group(1)), m.group(2)) if m else None
    # The runtime prints two top-level allocator-timing blocks:
    #   "Allocator Timings:" — top-level mutually-exclusive buckets
    #   "Allocator Nested Timings (...):" — sub-counters, do not sum
    # Both are scoped tightly so their labels cannot bleed into each other.
    timings_block_re = (r"Allocator Timings:\n"
                        r"(?P<body>(?:.*\n)+?)\n")
    m_top = re.search(timings_block_re, out_text)
    top_body = m_top.group("body") if m_top else ""
    helper_in_mutator_s = _first_time_seconds(
        top_body, r"Old-gen alloc in mutator:\s+" + _TIME_RE)
    nursery_alloc_s = _first_time_seconds(
        top_body, r"Nursery alloc in mutator:\s+" + _TIME_RE)
    nested_block_re = (r"Allocator Nested Timings[^:\n]*:\n"
                       r"(?P<body>(?:.*\n)+?)\n")
    m_nest = re.search(nested_block_re, out_text)
    nested_body = m_nest.group("body") if m_nest else ""
    helper_in_minor_s = _first_time_seconds(
        nested_body, r"In minor pauses[^:]*:\s+" + _TIME_RE)
    helper_s = helper_in_minor_s + helper_in_mutator_s

    # Pause log (ECO_GC_PHASE_TIMERS builds only).
    pause = re.search(r"all pauses" + _PAUSE_LINE_RE, out_text)
    minor_pause = re.search(r"minor-only pauses" + _PAUSE_LINE_RE, out_text)
    # The first MMU block covers pauses only; the optional second one
    # ("MMU incl. helper stalls") is not what the columns report.
    mmu = {}
    m_mmu = re.search(r"Minimum mutator utilisation \(MMU\):\n"
                      r"(?P<body>(?:\s+MMU\s+\d+ ms:\s+[0-9.]+%\n)+)", out_text)
    if m_mmu:
        for w, u in re.findall(r"MMU\s+(\d+) ms:\s+([0-9.]+)%",
                               m_mmu.group("body")):
            mmu[int(w)] = float(u)

    # Promotion: the retention block's promoted bytes (every build with
    # stats); region-mode tenuring and the old-gen in-use peak.
    promoted_mib = None
    m = re.search(r"totals: promoted \d+ \(([0-9.]+) (B|KiB|MiB|GiB)\)", out_text)
    if m:
        promoted_mib = _bytes_to_mib(float(m.group(1)), m.group(2))
    tenured_mb = _opt_float(out_text, r"tenured \d+ objects, ([0-9.]+) MB")
    oldgen_peak_mb = _opt_float(out_text, r"Old-gen in-use peak:\s+([0-9.]+) MB")

    # Thread CPU from the runtime's own clocks.
    m = re.search(r"mutator CPU ([0-9.]+) s, of which in pauses [0-9.]+ s; "
                  r"outside pauses ([0-9.]+) s", out_text)
    mutator_cpu_s = float(m.group(1)) if m else None
    mutator_cpu_out_s = float(m.group(2)) if m else None
    conc_mark_cpu_s = _opt_float(out_text, r"background CPU ([0-9.]+) s")
    collector_cpu_s = _opt_float(
        out_text, r"collector: busy [0-9.]+ s over epochs .*?\), CPU ([0-9.]+) s")
    late_minors = _opt_int(out_text, r"late minors (\d+)")

    # Time the compiler spent in the package-registry POST. Must be 0:
    # _freeze_registry_ttl() suppresses the call. See its docstring.
    registry_ms = 0
    for m in re.finditer(r"Registry: POST \S+ completed in (\d+)ms", out_text):
        registry_ms += int(m.group(1))

    peak = 0.0
    for m in re.finditer(r"tl\.committed=([0-9.]+)\s*MB", err_text):
        peak = max(peak, float(m.group(1)))
    live_matches = re.findall(r"tl\.live=([0-9.]+)\s*MB", err_text)
    final_live = float(live_matches[-1]) if live_matches else 0.0

    return {
        "wall_s": _fmt(wall_s, 2),
        "cpu_s": _fmt(time_v.get("cpu_s"), 2),
        "user_s": _fmt(time_v.get("user_s"), 2),
        "sys_s": _fmt(time_v.get("sys_s"), 2),
        "max_rss_GB": _fmt(time_v.get("max_rss_GB"), 3),
        "pause_n": int(pause.group(1)) if pause else "",
        "pause_total_s": _fmt(float(pause.group(2)) if pause else None, 3),
        "pause_p50_ms": _fmt(float(pause.group(3)) if pause else None, 3),
        "pause_p90_ms": _fmt(float(pause.group(4)) if pause else None, 3),
        "pause_p99_ms": _fmt(float(pause.group(5)) if pause else None, 3),
        "pause_p999_ms": _fmt(float(pause.group(6)) if pause else None, 3),
        "pause_max_ms": _fmt(float(pause.group(7)) if pause else None, 3),
        "minor_pause_max_ms": _fmt(
            float(minor_pause.group(7)) if minor_pause else None, 3),
        # 100/200/500 ms: at the TA2 baseline every window up to 50 ms reads
        # 0 % (the p99.9 pause is ~88 ms), so shorter windows cannot rank.
        "mmu_100ms_pct": _fmt(mmu.get(100), 2),
        "mmu_200ms_pct": _fmt(mmu.get(200), 2),
        "mmu_500ms_pct": _fmt(mmu.get(500), 2),
        "promoted_MiB": _fmt(promoted_mib, 1),
        "objs_promoted": _fmt(objs_promoted, 0),
        "tenured_MB": _fmt(tenured_mb, 1),
        "oldgen_peak_MB": _fmt(oldgen_peak_mb, 1),
        "minor_gcs": minor_gcs,
        "major_gcs": major_gcs,
        "gc_total_s": _fmt(gc_total_s, 2),
        "major_s": _fmt(major_s, 2),
        "minor_s": _fmt(minor_s, 2),
        "helper_s": _fmt(helper_s, 2),
        "nursery_alloc_s": _fmt(nursery_alloc_s, 2),
        "mutator_cpu_s": _fmt(mutator_cpu_s, 2),
        "mutator_cpu_out_s": _fmt(mutator_cpu_out_s, 2),
        "conc_mark_cpu_s": _fmt(conc_mark_cpu_s, 2),
        "collector_cpu_s": _fmt(collector_cpu_s, 2),
        "late_minors": _fmt(late_minors, 0),
        "bytes_alloc_MB": _fmt(bytes_mb, 2),
        "objs_alloc": objs,
        "peak_commit_MB": _fmt(peak, 2),
        "final_live_MB": _fmt(final_live, 2),
        "registry_ms": registry_ms,
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

def _pump(src, dest) -> None:
    """Forward bytes from `src` to `dest` as soon as they arrive.

    The destination is always the on-disk log file. Console echo (when --tee
    is set) is handled out-of-process by a `tail -F` subprocess so a slow or
    stalled terminal can never apply back-pressure to the child via the pipe.
    `read1` returns whatever the kernel has buffered without waiting to fill
    a 4 KiB block, so each line the child emits hits disk immediately."""
    while True:
        chunk = src.read1(4096)
        if not chunk:
            return
        dest.write(chunk)
        dest.flush()


def _start_tail(path: Path, dest_fd) -> subprocess.Popen | None:
    """Spawn `tail -n +1 -F <path>` writing to `dest_fd` (the parent's stdout
    or stderr). Returns the Popen, or None if `tail` is unavailable."""
    try:
        return subprocess.Popen(
            ["tail", "-n", "+1", "-F", str(path)],
            stdout=dest_fd, stderr=subprocess.DEVNULL,
            start_new_session=True)
    except FileNotFoundError:
        print("[heap-profile] WARNING: `tail` not found on PATH; --tee will "
              "be silent. Logs are still written to the variant dir.",
              file=sys.stderr, flush=True)
        return None


def _stop_tail(tp: subprocess.Popen | None) -> None:
    if tp is None:
        return
    try:
        tp.terminate()
        try:
            tp.wait(timeout=2)
        except subprocess.TimeoutExpired:
            tp.kill()
            try:
                tp.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
    except ProcessLookupError:
        pass


def _run_capturing(cmd, *, cwd, env, out_path: Path, err_path: Path,
                   tee: bool) -> int:
    """Run `cmd`, writing stdout/stderr to the given log files. When `tee` is
    set, the output is also forwarded live to the parent's stdout/stderr via
    a `tail -F` subprocess on each log file.

    Reliability notes:

    * The child is force-line-buffered via `stdbuf -oL -eL`. Without this,
      glibc switches stdio to block-buffered mode whenever stdout is a pipe
      (which is the case under tee), and you see no output until 4 KiB have
      accumulated or the process exits.
    * The pump threads write only to the log file. The on-disk write goes to
      the page cache and essentially never blocks, so the child's pipe is
      drained as fast as it produces bytes. Earlier versions also wrote to
      `sys.stdout.buffer` from the pump thread; a slow or stopped terminal
      could stall that flush, fill the 64 KiB pipe, and park eco-compiler in
      a kernel `write(2)` (visible as a 0%-CPU "freeze" in `top`). Console
      echo now lives in a separate `tail -F` process that the child cannot
      see, so terminal back-pressure can no longer reach it.
    * The child runs in its own process group (`start_new_session=True`) so a
      Ctrl+C in the parent doesn't double-fire on the child. We translate
      KeyboardInterrupt into SIGTERM-to-the-process-group, which lets
      eco-compiler's SIGTERM handler print GC stats before exiting; we then
      drain its stdout/stderr (which carries those stats) before re-raising.
    """
    line_buffered_cmd = ["stdbuf", "-oL", "-eL", *cmd]
    variant_dir = out_path.parent

    def _start_watchdog(proc: subprocess.Popen) -> tuple[threading.Thread, threading.Event]:
        stop_evt = threading.Event()
        t = threading.Thread(target=_watchdog, kwargs={
            "proc": proc, "out_path": out_path, "err_path": err_path,
            "variant_dir": variant_dir, "stop_evt": stop_evt})
        t.daemon = True
        t.start()
        return t, stop_evt

    if not tee:
        with out_path.open("wb") as out, err_path.open("wb") as err:
            proc = subprocess.Popen(line_buffered_cmd, cwd=cwd, env=env,
                                    stdout=out, stderr=err,
                                    start_new_session=True)
            wd_t, wd_stop = _start_watchdog(proc)
            try:
                return proc.wait()
            except KeyboardInterrupt:
                _shutdown_child(proc)
                raise
            finally:
                wd_stop.set()
                wd_t.join(timeout=5)

    # Open the log files unbuffered (buffering=0) so `tail -F` sees bytes the
    # instant the pump thread writes them, without depending on Python's
    # block buffer being flushed by an explicit call.
    with out_path.open("wb", buffering=0) as out_f, \
            err_path.open("wb", buffering=0) as err_f:
        tail_out = _start_tail(out_path, sys.stdout)
        tail_err = _start_tail(err_path, sys.stderr)
        try:
            proc = subprocess.Popen(line_buffered_cmd, cwd=cwd, env=env,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE,
                                    start_new_session=True)
            t_out = threading.Thread(target=_pump, args=(proc.stdout, out_f))
            t_err = threading.Thread(target=_pump, args=(proc.stderr, err_f))
            t_out.start()
            t_err.start()
            wd_t, wd_stop = _start_watchdog(proc)
            try:
                rc = proc.wait()
            except KeyboardInterrupt:
                _shutdown_child(proc)
                t_out.join()
                t_err.join()
                raise
            finally:
                wd_stop.set()
                wd_t.join(timeout=5)
            t_out.join()
            t_err.join()
            return rc
        finally:
            _stop_tail(tail_out)
            _stop_tail(tail_err)


_SHUTDOWN_GRACE_S = 15

# How long the child can be silent (no growth in either log file) before the
# watchdog dumps its kernel stacks. Raised 60 -> 180 once runs stopped being
# truncated at 60 s: a full self-compile has quiet phases of several minutes
# (mono, codegen) that print nothing, and 60 s misclassified them as stalls —
# three spurious dumps in one run. A real stall still surfaces within 3 min,
# and the dump re-arms, so a genuinely stuck run keeps producing evidence.
_STALL_THRESHOLD_S = 180
_WATCHDOG_POLL_S = 2


def _proc_descendants(root_pid: int) -> list[int]:
    """Return [root_pid] followed by every PID transitively descended from
    it, using /proc/<pid>/task/<tid>/children. Best-effort: exited PIDs are
    silently dropped."""
    out = [root_pid]
    seen = {root_pid}
    queue = [root_pid]
    while queue:
        pid = queue.pop()
        try:
            for tid_dir in Path(f"/proc/{pid}/task").iterdir():
                try:
                    children = (tid_dir / "children").read_text().split()
                except (FileNotFoundError, ProcessLookupError):
                    continue
                for c in children:
                    cp = int(c)
                    if cp not in seen:
                        seen.add(cp)
                        out.append(cp)
                        queue.append(cp)
        except (FileNotFoundError, NotADirectoryError, ProcessLookupError):
            continue
    return out


def _read_proc_file(path: Path) -> str:
    try:
        text = path.read_text(errors="replace")
    except (FileNotFoundError, PermissionError, ProcessLookupError) as e:
        return f"# could not read {path}: {e}\n"
    if not text.endswith("\n"):
        text += "\n"
    return text


def _dump_proc_tree(root_pid: int, dump_path: Path) -> None:
    """Dump kernel state of the entire process tree under `root_pid`.

    For each PID we record `comm`, `status`, `wchan`, `syscall`, `stack`. Then
    — crucially for diagnosing pthread_join / futex stalls — we walk
    /proc/<pid>/task/<tid>/ and dump the same fields for every thread, since
    the main thread alone tells you nothing about which worker is hung.
    """
    pids = _proc_descendants(root_pid)
    with dump_path.open("w") as f:
        f.write(f"# stall dump @ {datetime.now(timezone.utc).isoformat()}\n")
        f.write(f"# root pid: {root_pid}\n")
        f.write(f"# tree: {pids}\n")
        for pid in pids:
            f.write(f"\n## pid {pid}\n")
            for fname in ("comm", "status", "wchan", "syscall", "stack"):
                f.write(f"### {fname}\n")
                f.write(_read_proc_file(Path(f"/proc/{pid}/{fname}")))
            task_dir = Path(f"/proc/{pid}/task")
            try:
                tids = sorted(int(p.name) for p in task_dir.iterdir())
            except (FileNotFoundError, NotADirectoryError, ProcessLookupError):
                continue
            for tid in tids:
                if tid == pid:
                    continue
                f.write(f"\n### thread {tid} (pid {pid})\n")
                for fname in ("comm", "status", "wchan", "syscall", "stack"):
                    f.write(f"#### {fname}\n")
                    f.write(_read_proc_file(
                        Path(f"/proc/{pid}/task/{tid}/{fname}")))


def _watchdog(*, proc: subprocess.Popen, out_path: Path, err_path: Path,
              variant_dir: Path, stop_evt: threading.Event) -> None:
    """Detects stalls and dumps kernel stacks for the child process tree.

    Heuristic: if neither log file has grown for `_STALL_THRESHOLD_S`, the
    child is no longer producing output. We dump `/proc/<pid>/{status,wchan,
    syscall,stack,comm}` for `proc.pid` and every descendant. `proc.pid` is
    eco-compiler itself, or the timeout(1) wrapper it runs under when
    --wall-seconds is given, in which case eco-compiler is a descendant. The dump goes into
    `variant_dir/stall_NNN.txt` so it survives the run for offline analysis.
    After dumping we re-arm: another `_STALL_THRESHOLD_S` of silence triggers
    another dump (with a fresh sequence number), so a long stall produces a
    timeline rather than a single snapshot."""

    def _sizes() -> tuple[int, int]:
        try:
            return out_path.stat().st_size, err_path.stat().st_size
        except FileNotFoundError:
            return 0, 0

    last_size = _sizes()
    last_change = time.monotonic()
    seq = 0
    while not stop_evt.wait(_WATCHDOG_POLL_S):
        cur = _sizes()
        if cur != last_size:
            last_size = cur
            last_change = time.monotonic()
            continue
        if time.monotonic() - last_change < _STALL_THRESHOLD_S:
            continue
        seq += 1
        dump_path = variant_dir / f"stall_{seq:03d}.txt"
        try:
            _dump_proc_tree(proc.pid, dump_path)
            print(f"[heap-profile] stall detected (no log growth for "
                  f"{_STALL_THRESHOLD_S}s) — dumped {dump_path}",
                  file=sys.stderr, flush=True)
        except Exception as e:
            print(f"[heap-profile] watchdog dump failed: {e}",
                  file=sys.stderr, flush=True)
        last_change = time.monotonic()


def _shutdown_child(proc: subprocess.Popen) -> None:
    """Translate a Ctrl+C in the parent into a graceful shutdown of the child:

    1. SIGTERM the child's process group — eco-compiler directly, or the
       timeout(1) wrapper under --wall-seconds, which forwards the signal.
       eco-compiler's SIGTERM handler in eco_entry.cpp writes the
       `[gc-stats] SIGTERM — printing GC statistics` marker and then prints
       the full GC-stats block to stdout.
    2. Wait up to _SHUTDOWN_GRACE_S seconds for it to exit. The
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


def _clear_eco_stuff() -> None:
    """Remove `compiler/build-kernel/eco-stuff/` so each variant starts from the
    same cold cache. eco-compiler recreates the directory and repopulates it on
    its next `make`.

    The whole directory goes, not a version subfolder: the package version is
    part of the path (`eco-stuff/0.1.1/` today, `eco-stuff/1.0.0/` when this
    script was written) and a hard-coded version silently stops matching on a
    bump, leaving every variant to run warm off its predecessor's cache. This
    is what benchmarks/lss-loop-ab.sh does."""
    if ECO_STUFF.exists():
        shutil.rmtree(ECO_STUFF)


def _freeze_registry_ttl() -> list[Path]:
    """Refresh the mtime of every cached `registry.dat` so the compiler skips
    its package-registry POST, and return the files touched.

    Deleting `eco-stuff/` forces dependency re-verification, which calls
    `Registry.update`. Under the `Normal` policy that hits the network unless
    `registry.dat` was modified within the last 30 minutes
    (`compiler/src/Builder/Deps/Registry.elm:208`). Measured here, that POST
    took **134 s** and then FAILED — and a failed update neither writes nor
    touches the file, so the TTL never resets by itself and every subsequent
    run pays it again. Left alone it lands inside the measured wall and is
    charged to mutator time, which is the metric a sweep is scored on.

    The package cache is `$ECO_HOME` if set, else `~/.eco`
    (`compiler/src/Builder/Stuff.elm:411`); every version directory under it is
    touched, since the cache is versioned. This only suppresses the registry
    REFRESH — the cached registry and the packages themselves are untouched,
    which is what the benchmark protocol wants: cache intact, `eco-stuff` cold.
    `parse_summary` records `registry_ms` so a run that somehow still makes the
    call cannot pass unnoticed."""
    eco_home = Path(os.environ.get("ECO_HOME") or (Path.home() / ".eco"))
    touched = []
    for dat in sorted(eco_home.glob("*/packages/registry.dat")):
        try:
            dat.touch()
            touched.append(dat)
        except OSError as e:
            print(f"WARNING: could not touch {dat}: {e} — the run may make a "
                  f"package-registry network call.", flush=True)
    if not touched:
        print(f"WARNING: no registry.dat under {eco_home} — the run may make a "
              f"package-registry network call.", flush=True)
    return touched


def _pids_running(exe: Path) -> list[str]:
    """PIDs whose executable IS `exe` (/proc/<pid>/exe), not merely processes
    whose command line mentions the path."""
    target = str(exe.resolve())
    pids = []
    for d in Path("/proc").iterdir():
        if d.name.isdigit():
            try:
                if os.readlink(d / "exe") == target:
                    pids.append(d.name)
            except OSError:
                continue
    return pids


def run_once(*, name: str, rep: int, change: str, cfg_path: Path,
             rep_dir: Path, wall_seconds: int | None, tee: bool,
             heap_trace: bool, preserve_eco_stuff: bool) -> dict:
    """Runs the compiler once under GNU `time -v` and writes this run's logs
    and TSVs into `rep_dir`. Returns the raw row (keyed by RAW_COLUMNS);
    validity against the reference output is decided by the caller."""
    # A killed harness (e.g. Claude Code's memory-pressure reaper) leaves its
    # compiler child running in its own session. A resumed sweep would then
    # time every run against that orphan, so refuse to start instead.
    others = _pids_running(ECO_COMPILER)
    if others:
        sys.exit(f"ERROR: {ECO_COMPILER.name} is already running (pid "
                 f"{', '.join(others)}), probably left over from a killed "
                 f"sweep. Stop it before resuming; its run was never recorded.")
    rep_dir.mkdir(parents=True, exist_ok=True)
    out_path = rep_dir / "stdout.log"
    err_path = rep_dir / "stderr.log"
    time_path = rep_dir / "time.txt"

    if not preserve_eco_stuff:
        _clear_eco_stuff()
    _freeze_registry_ttl()

    boot_mlir = BUILD_KERNEL / "bin" / "eco-compiler-boot.mlir"
    if boot_mlir.exists():
        boot_mlir.unlink()

    env = os.environ | {
        "ECO_HEAP_CONFIG": str(cfg_path),
        "ECO_HEAP_TRACE": "1" if heap_trace else "0",
        "ECO_GC_PHASE_PROFILE": "1",
    }
    # With no --wall-seconds the compiler is run directly, to completion.
    # With one, timeout(1) SIGTERMs it at the budget; eco-compiler's handler
    # prints the GC statistics before exiting, so a truncated run still parses.
    budget = ([] if wall_seconds is None else
              ["/usr/bin/timeout", f"--kill-after={KILL_AFTER_S}s",
               str(wall_seconds)])
    # time(1) sits outermost so its rusage covers the whole tree (timeout's
    # child included). It stays in the child's process group, so Ctrl+C's
    # SIGTERM still reaches eco-compiler, and it writes to its own file, so
    # the compiler's stderr is untouched.
    cmd = [
        "/usr/bin/time", "-v", "-o", str(time_path),
        *budget,
        str(ECO_COMPILER), "make",
        "--optimize",
        "--kernel-package", "eco/compiler",
        "--local-package", f"eco/kernel={REPO_ROOT}/eco-kernel-cpp",
        "--output=bin/eco-compiler-boot.mlir",
        str(ELM_ENTRY),
    ]

    budget_desc = ("to completion" if wall_seconds is None
                   else f"wall_seconds={wall_seconds}")
    print(f"\n=== {name} r{rep}  ({change}) — {budget_desc} ===", flush=True)
    t0 = time.time()
    rc = _run_capturing(cmd, cwd=BUILD_KERNEL, env=env,
                        out_path=out_path, err_path=err_path, tee=tee)
    elapsed = time.time() - t0
    out_text = out_path.read_text(errors="replace")
    err_text = err_path.read_text(errors="replace")
    time_v = parse_time_v(time_path.read_text(errors="replace")
                          if time_path.exists() else "")

    # The runtime's fatal-signal handler writes this marker before printing
    # stats. Checking it is NOT redundant with rc: on 2026-09-22 `abuf_128K`
    # took SIGSEGV and still exited 0, so rc alone reported a crashed run as a
    # 61.7 s "win". Never treat rc=0 as proof that a run completed.
    crashed = re.search(r"\[gc-stats\] (SIG[A-Z]+) ", err_text)

    # rc 124 is timeout(1)'s "budget expired", possible only under --wall-seconds.
    truncated = rc == 124
    wall_s = float(wall_seconds) if truncated else elapsed
    if truncated:
        print(f"WARNING: {name} r{rep} hit the {wall_seconds}s budget — the "
              f"run is TRUNCATED; its GC totals cover only that window.",
              flush=True)
    elif rc != 0:
        print(f"WARNING: {name} r{rep} exited rc={rc} — the run is INVALID "
              f"even if its output hash matches. Check {err_path}", flush=True)
    if crashed:
        print(f"WARNING: {name} r{rep} took {crashed.group(1)} (rc={rc}) — the "
              f"run did NOT complete; its wall and GC totals cover only the "
              f"time before the crash and must not be read as a result.",
              flush=True)

    row = parse_summary(out_text, err_text, wall_s, time_v)
    row["name"] = name
    row["rep"] = rep
    row["change"] = change
    row["rc"] = rc
    row["signal"] = crashed.group(1) if crashed else ""
    # Fingerprint the compiler's OUTPUT. A heap config must not change what the
    # compiler emits; if one does, that is a miscompile, and without this it
    # would read as a win (the fastest cell is exactly where the risk bites).
    # Every run overwrites this path, so the hash has to be taken per run.
    if boot_mlir.exists():
        data = boot_mlir.read_bytes()
        row["out_bytes"] = len(data)
        row["out_md5"] = hashlib.md5(data).hexdigest()
    else:
        row["out_bytes"] = 0
        row["out_md5"] = "MISSING"
        print(f"WARNING: {name} r{rep} produced no {boot_mlir.name} — the "
              f"compile did not reach its output stage.", flush=True)
    if row["registry_ms"]:
        print(f"WARNING: {name} r{rep} made a package-registry network call "
              f"costing {row['registry_ms'] / 1000:.1f}s — that time is INSIDE "
              f"wall_s. See _freeze_registry_ttl().", flush=True)
    # Provisional: rc, signal and output presence. run_cell adds the
    # comparison against the reference hash.
    row["valid"] = (rc == 0 and not crashed and row["out_md5"] != "MISSING")

    nursery_rows = parse_alloc_histogram(
        out_text, "Nursery Allocation Size Histogram")
    oldgen_rows = parse_alloc_histogram(
        out_text, "Old-Gen Allocation Size Histogram")
    string_rows = parse_alloc_histogram(
        out_text, "String Allocation Size Histogram")
    write_tsv(rep_dir / "alloc_size_nursery.tsv",
              ["bucket", "count", "percent"], nursery_rows)
    write_tsv(rep_dir / "alloc_size_oldgen.tsv",
              ["bucket", "count", "percent"], oldgen_rows)
    write_tsv(rep_dir / "alloc_size_strings.tsv",
              ["bucket", "count", "percent"], string_rows)

    resid_cols = ["kind", "label", "pages", "page_bytes", "live_bytes",
                  "free_bytes", "garbage_bytes",
                  "live_pct", "free_pct", "garb_pct"]
    cum_buckets, cum_totals = parse_residency_histogram(
        out_text, "cumulative")
    latest_buckets, latest_totals = parse_residency_histogram(
        out_text, "latest: most recent major-GC end")
    write_tsv(rep_dir / "residency_cumulative.tsv", resid_cols,
              cum_buckets + cum_totals)
    write_tsv(rep_dir / "residency_latest.tsv", resid_cols,
              latest_buckets + latest_totals)

    fl_cols = ["label", "cells", "bytes", "percent_bytes"]
    write_tsv(rep_dir / "freelist_cumulative.tsv", fl_cols,
              parse_freelist_histogram(out_text, "cumulative"))
    write_tsv(rep_dir / "freelist_latest.tsv", fl_cols,
              parse_freelist_histogram(
                  out_text, "latest: most recent major-GC end"))

    print(f"rc={rc}  wall={row['wall_s']}s  cpu={row['cpu_s']}s  "
          f"rss={row['max_rss_GB']}GB  p99={row['pause_p99_ms'] or '-'}ms  "
          f"max={row['pause_max_ms'] or '-'}ms  promoted={row['promoted_MiB']}MiB",
          flush=True)
    return row


def _median(values: list[str]) -> float | None:
    nums = []
    for v in values:
        if v in ("", None):
            continue
        try:
            nums.append(float(v))
        except ValueError:
            continue
    if not nums:
        return None
    nums.sort()
    n = len(nums)
    return nums[n // 2] if n % 2 else (nums[n // 2 - 1] + nums[n // 2]) / 2


def median_row(name: str, change: str, rows: list[dict]) -> dict:
    """The cell's summary: each metric's median over its VALID runs. Integer
    counters stay integers when every run agrees (they are exact per binary),
    so a median that is not a whole number is visible as such."""
    valid = [r for r in rows if str(r.get("valid")) in ("True", "true")]
    out = {"name": name, "change": change, "runs": len(rows),
           "valid_runs": len(valid)}
    for col in METRIC_COLUMNS:
        med = _median([r.get(col, "") for r in valid])
        if med is None:
            out[col] = ""
        elif med == int(med) and all(
                "." not in str(r.get(col, "")) for r in valid):
            out[col] = int(med)
        else:
            out[col] = f"{med:.3f}"
    md5s = {r.get("out_md5") for r in rows}
    out["out_md5"] = md5s.pop() if len(md5s) == 1 else "MIXED"
    return out


def _read_tsv_rows(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with path.open() as f:
        cols = f.readline().rstrip("\n").split("\t")
        return [dict(zip(cols, line.rstrip("\n").split("\t"))) for line in f]


def run_cell(*, name: str, change: str, heap_config: dict, group_dir: Path,
             repeat: int, ref: dict, wall_seconds: int | None, tee: bool,
             heap_trace: bool, preserve_eco_stuff: bool) -> dict:
    """Runs one cell `repeat` times, strictly serially, and returns its
    median row. Repeats already in `group_dir/runs_raw.tsv` are reused, so an
    interrupted sweep resumes mid-cell. `ref` holds the reference output hash
    (the first valid run of the sitting, normally `baseline`): a run whose
    output differs is a MISCOMPILE and is excluded from the medians."""
    variant_dir = group_dir / "variants" / name
    variant_dir.mkdir(parents=True, exist_ok=True)
    cfg_path = variant_dir / "heap-config.json"
    cfg_path.write_text(json.dumps(heap_config, indent=2) + "\n")

    raw_path = group_dir / "runs_raw.tsv"
    rows = [r for r in _read_tsv_rows(raw_path) if r.get("name") == name]
    done = {int(r["rep"]) for r in rows if r.get("rep", "").isdigit()}
    for rep in range(1, repeat + 1):
        if rep in done:
            print(f"SKIP {name} r{rep} (already in runs_raw.tsv)", flush=True)
            continue
        row = run_once(name=name, rep=rep, change=change, cfg_path=cfg_path,
                       rep_dir=variant_dir / f"r{rep}",
                       wall_seconds=wall_seconds, tee=tee,
                       heap_trace=heap_trace,
                       preserve_eco_stuff=preserve_eco_stuff)
        if row["valid"]:
            if ref.get("md5") is None:
                ref["md5"], ref["name"] = row["out_md5"], f"{name} r{rep}"
            elif row["out_md5"] != ref["md5"]:
                row["valid"] = False
                print(f"WARNING: {name} r{rep} OUTPUT DIFFERS from {ref['name']} "
                      f"({row['out_md5']} vs {ref['md5']}). A heap config must "
                      f"not change the emitted code — this run is a MISCOMPILE, "
                      f"not a result, and is excluded from the medians.",
                      flush=True)
        append_tsv_row(raw_path, RAW_COLUMNS, row)
        rows.append(row)

    rows.sort(key=lambda r: int(r["rep"]))
    write_tsv(variant_dir / "runs.tsv", RAW_COLUMNS, rows)
    summary = median_row(name, change, rows)
    write_tsv(variant_dir / "summary.tsv", SUMMARY_COLUMNS, [summary])
    if summary["valid_runs"] < summary["runs"]:
        print(f"WARNING: {name}: only {summary['valid_runs']} of "
              f"{summary['runs']} runs are valid; the medians use those only.",
              flush=True)
    print(f"--- {name} median of {summary['valid_runs']}: "
          f"wall={summary['wall_s']}s cpu={summary['cpu_s']}s "
          f"rss={summary['max_rss_GB']}GB p99={summary['pause_p99_ms'] or '-'}ms "
          f"max={summary['pause_max_ms'] or '-'}ms", flush=True)
    return summary


def reference_from_raw(group_dir: Path) -> dict:
    """On resume, the reference hash is the first valid run already recorded."""
    for r in _read_tsv_rows(group_dir / "runs_raw.tsv"):
        if r.get("valid") in ("True", "true") and r.get("out_md5") not in ("", "MISSING"):
            return {"md5": r["out_md5"], "name": f"{r['name']} r{r['rep']}"}
    return {"md5": None, "name": None}


# ---------------------------------------------------------------------------
# Report writing
# ---------------------------------------------------------------------------

def write_report(group_dir: Path, *, mode: str, machine: str, ts: str,
                 wall_seconds: int | None, command_line: list[str],
                 summary_rows: list[dict], repeat: int) -> None:
    md = []
    md.append(f"# heap-profile {mode} report")
    md.append("")
    md.append(f"- machine: `{machine}`")
    md.append(f"- timestamp: `{ts}` (UTC)")
    md.append(f"- build tree: `{BUILD_TREE.name}` (binary `{ECO_COMPILER.name}`)")
    md.append(f"- compiler MLIR: `{ECO_COMPILER_MLIR}`")
    md.append(f"- runs per cell: {repeat}; every figure below is the MEDIAN "
              "over the cell's valid runs (rc 0, no signal, output hash equal "
              "to the reference)")
    md.append("- wall budget: "
              + ("`none` (each run went to completion)" if wall_seconds is None
                 else f"`{wall_seconds}s` (runs truncated at the budget)"))
    md.append(f"- command: `{' '.join(command_line)}`")
    md.append("")
    md.append("Empty pause/MMU cells mean the binary has no pause log (not an "
              "`ECO_GC_PHASE_TIMERS` build). CPU is user + sys of the whole "
              "process tree; RSS is its peak.")
    md.append("")
    md.append("## Summary")
    md.append("")
    md.append("| name | change | valid | wall s | CPU s | RSS GB | pause p50 / p99 / max ms "
              "| MMU 200 ms % | promoted MiB | minors / majors | GC s "
              "| mutator CPU out s | collector CPU s | out_md5 |")
    md.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|")
    for r in summary_rows:
        md.append(
            f"| [{r['name']}](variants/{r['name']}/runs.tsv) | {r['change']} "
            f"| {r['valid_runs']}/{r['runs']} | {r['wall_s']} | {r['cpu_s']} "
            f"| {r['max_rss_GB']} "
            f"| {r['pause_p50_ms']} / {r['pause_p99_ms']} / {r['pause_max_ms']} "
            f"| {r['mmu_200ms_pct']} | {r['promoted_MiB']} "
            f"| {r['minor_gcs']} / {r['major_gcs']} | {r['gc_total_s']} "
            f"| {r['mutator_cpu_out_s']} | {r['collector_cpu_s']} "
            f"| `{str(r['out_md5'])[:8]}` |")
    md.append("")
    md.append("## Files")
    md.append("")
    md.append("- [`runs.tsv`](runs.tsv) — one MEDIAN row per cell (also the "
              "resume marker)")
    md.append("- [`runs_raw.tsv`](runs_raw.tsv) — every run, with rc, signal, "
              "output hash and validity")
    md.append("- [`args.json`](args.json) — CLI arguments + rebuild outcome")
    md.append("- `variants/<name>/` — `heap-config.json`, `summary.tsv` "
              "(median), `runs.tsv` (raw), and `r<N>/` per run: "
              "`stdout.log` (stats banner), `stderr.log`, `time.txt` "
              "(`time -v`), allocation / residency / free-list TSVs")
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
        # Absolute: the compiler runs with cwd = build-kernel, so a relative
        # group dir breaks `time -o` and ECO_HEAP_CONFIG (every run rc 125).
        resume_dir = resume_dir.resolve()
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
    rebuild = ensure_binaries_fresh(args.skip_rebuild, args.bootstrap)
    cfg_path = Path(args.config or DEFAULT_HEAP_CONFIG)
    if not cfg_path.exists():
        sys.exit(f"ERROR: heap config {cfg_path} does not exist")
    heap_config = json.loads(cfg_path.read_text())

    group_dir, ts = make_group_dir(results_root, machine, "run",
                                   args.label, args.resume_dir)
    name = args.label or "default"

    done = previously_done_names(group_dir)
    if name in done:
        print(f"SKIP {name} (already in {group_dir / 'runs.tsv'})", flush=True)
        return

    summary = run_cell(
        name=name, change=f"config={cfg_path.name}",
        heap_config=heap_config, group_dir=group_dir, repeat=args.repeat,
        ref=reference_from_raw(group_dir), wall_seconds=args.wall_seconds,
        tee=args.tee, heap_trace=args.heap_trace,
        preserve_eco_stuff=args.preserve_eco_stuff)

    append_tsv_row(group_dir / "runs.tsv", SUMMARY_COLUMNS, summary)
    (group_dir / "args.json").write_text(json.dumps({
        "argv": sys.argv,
        "machine": machine,
        "results_root": str(results_root),
        "timestamp_utc": ts,
        "wall_seconds": args.wall_seconds,
        "repeat": args.repeat,
        "config": str(cfg_path),
        "rebuild": rebuild,
    }, indent=2))
    write_report(group_dir, mode="run", machine=machine, ts=ts,
                 wall_seconds=args.wall_seconds,
                 command_line=sys.argv,
                 summary_rows=[summary], repeat=args.repeat)
    print(f"\nReport: {group_dir / 'report.md'}", flush=True)


def _detect_variant(run_dir: Path, label: str | None) -> Path:
    """Resolve `<run_dir>/variants/<label>` — pick the only variant if
    none was given, error if ambiguous."""
    vroot = run_dir / "variants"
    if not vroot.is_dir():
        raise SystemExit(f"missing {vroot} (not a run-group directory?)")
    candidates = sorted(p for p in vroot.iterdir() if p.is_dir())
    if not candidates:
        raise SystemExit(f"no variants under {vroot}")
    if label:
        chosen = vroot / label
        if not chosen.is_dir():
            raise SystemExit(f"variant {label!r} not under {vroot}; "
                             f"available: {[c.name for c in candidates]}")
    elif len(candidates) > 1:
        raise SystemExit(f"multiple variants in {vroot} — pass --variant-* "
                         f"to disambiguate: {[c.name for c in candidates]}")
    else:
        chosen = candidates[0]
    # Repeated runs keep their TSVs in r<N>/. Allocation histograms are
    # identical across the repeats of a cell, so the first one stands in.
    if (chosen / "r1").is_dir() and not (chosen / "alloc_size_nursery.tsv").exists():
        return chosen / "r1"
    return chosen


def _read_alloc_tsv(path: Path) -> dict[str, int]:
    """Read a `bucket\\tcount\\tpercent` TSV produced by the runtime
    alloc-size histograms and return {bucket: count}. Skips the header
    row. Treats missing files as empty."""
    if not path.exists():
        return {}
    out: dict[str, int] = {}
    with path.open() as f:
        next(f, None)  # header
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            try:
                out[parts[0]] = int(parts[1])
            except ValueError:
                continue
    return out


def _bucket_bytes_estimate(bucket: str) -> int:
    """Coarse byte midpoint estimate from a bucket label like
    `'32 B -     64 B'`. Used to convert object-count deltas into a
    bytes-allocated estimate for the ranking column. Returns 0 if the
    label doesn't parse — the rank just falls to the bottom in that
    case."""
    import re
    parts = re.findall(r"(\d+)\s*([KMG]?)i?B", bucket)
    if len(parts) < 2:
        return 0
    def to_bytes(num: str, unit: str) -> int:
        n = int(num)
        return {"":1, "K":1024, "M":1024*1024, "G":1024*1024*1024}[unit] * n
    a, b = to_bytes(*parts[0]), to_bytes(*parts[1])
    return (a + b) // 2


def cmd_diff(args) -> None:
    """Compare per-size-class allocation tables between two run dirs.

    Pulls `alloc_size_{nursery,oldgen,strings}.tsv` from each variant
    directory and prints a per-bucket delta table (count and an
    estimated bytes contribution). Helps localise which allocation
    size classes account for an alloc-rate gap between two
    configurations."""
    base_variant = _detect_variant(args.baseline, args.variant_baseline)
    targ_variant = _detect_variant(args.target, args.variant_target)
    print(f"baseline: {base_variant}")
    print(f"target:   {targ_variant}")

    for histogram in ("alloc_size_nursery.tsv",
                      "alloc_size_oldgen.tsv",
                      "alloc_size_strings.tsv"):
        base = _read_alloc_tsv(base_variant / histogram)
        targ = _read_alloc_tsv(targ_variant / histogram)
        if not base and not targ:
            continue
        all_buckets = sorted(set(base) | set(targ),
                             key=lambda k: -_bucket_bytes_estimate(k))
        print(f"\n=== {histogram} (count delta target - baseline) ===")
        print(f"  {'bucket':<22} {'baseline':>14} {'target':>14} "
              f"{'delta':>14} {'~bytes delta':>16}")
        total_count_delta = 0
        total_bytes_delta = 0
        for b in all_buckets:
            bc = base.get(b, 0)
            tc = targ.get(b, 0)
            d = tc - bc
            est_bytes = d * _bucket_bytes_estimate(b)
            total_count_delta += d
            total_bytes_delta += est_bytes
            if d == 0:
                continue
            print(f"  {b:<22} {bc:>14d} {tc:>14d} {d:>+14d} {est_bytes:>+16d}")
        print(f"  {'TOTAL':<22} {sum(base.values()):>14d} "
              f"{sum(targ.values()):>14d} "
              f"{total_count_delta:>+14d} {total_bytes_delta:>+16d}")


def cmd_sweep(args, machine: str, results_root: Path) -> None:
    rebuild = ensure_binaries_fresh(args.skip_rebuild, args.bootstrap)
    selected = None
    if args.variants:
        selected = set(s.strip() for s in args.variants.split(",") if s.strip())
    variants = (load_variants_file(args.variants_file)
                if args.variants_file else VARIANTS)
    group_dir, ts = make_group_dir(results_root, machine, "sweep",
                                   args.label, args.resume_dir)
    done = previously_done_names(group_dir)
    summary_rows = _read_tsv_rows(group_dir / "runs.tsv")
    ref = reference_from_raw(group_dir)

    for name, change, overrides in variants:
        if selected is not None and name not in selected:
            continue
        if name in done:
            print(f"SKIP {name} (already in runs.tsv)", flush=True)
            continue
        summary = run_cell(
            name=name, change=change, heap_config=BASELINE_HEAP | overrides,
            group_dir=group_dir, repeat=args.repeat, ref=ref,
            wall_seconds=args.wall_seconds, tee=args.tee,
            heap_trace=args.heap_trace,
            preserve_eco_stuff=args.preserve_eco_stuff)
        append_tsv_row(group_dir / "runs.tsv", SUMMARY_COLUMNS, summary)
        summary_rows.append(summary)
        # Rewrite the report after every cell so a long sweep can be read
        # while it runs.
        write_report(group_dir, mode="sweep", machine=machine, ts=ts,
                     wall_seconds=args.wall_seconds, command_line=sys.argv,
                     summary_rows=summary_rows, repeat=args.repeat)

    (group_dir / "args.json").write_text(json.dumps({
        "argv": sys.argv,
        "machine": machine,
        "results_root": str(results_root),
        "timestamp_utc": ts,
        "wall_seconds": args.wall_seconds,
        "repeat": args.repeat,
        "variants_file": str(args.variants_file) if args.variants_file else None,
        "variants_filter": sorted(selected) if selected else None,
        "reference_output": ref,
        "rebuild": rebuild,
    }, indent=2))
    write_report(group_dir, mode="sweep", machine=machine, ts=ts,
                 wall_seconds=args.wall_seconds,
                 command_line=sys.argv,
                 summary_rows=summary_rows, repeat=args.repeat)
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
    p.add_argument("--preserve-eco-stuff", action="store_true",
                   help="do NOT delete compiler/build-kernel/eco-stuff "
                        "before each variant run. Off by default; the "
                        "directory is wiped per-run so every variant starts "
                        "from the same cold cache.")
    p.add_argument("--list-variants", action="store_true",
                   help="print the sweep variants table and exit")
    p.add_argument("--compiler-mlir",
                   help="lower this compiler MLIR (cached as "
                        "build-kernel/bin/<stem>.o) instead of the bootstrap "
                        "product eco-compiler.mlir. The threaded-GC baseline "
                        "is snapshots/lss-loop/keep-TA2/bin/ecoTG6base.mlir.")
    p.add_argument("--bootstrap", action="store_true",
                   help="allow a missing/stale eco-compiler.mlir to be "
                        "rebuilt by bootstrap Stages 1-6. This DELETES "
                        "build/compiler/build-kernel/bin/ first, including "
                        "any snapshot binaries kept there.")
    p.add_argument("--build-tree", default="build",
                   help="build tree whose runtime archives the profiled "
                        "compiler is linked against (default: build). Use "
                        "build-phasetimers for pause percentiles and MMU: "
                        "the object file is still lowered by build/, only "
                        "the link differs. The binary is "
                        "eco-compiler-<tree> for a non-default tree.")

    sub = p.add_subparsers(dest="cmd", required=False)

    pr = sub.add_parser("run", help="single run with one heap config")
    pr.add_argument("--config", help=f"heap config JSON "
                    f"(default {DEFAULT_HEAP_CONFIG})")
    pr.add_argument("--label", help="folder label (default: 'default')")
    pr.add_argument("--wall-seconds", type=int, default=None,
                    help="optional per-run wall budget in seconds. Default: "
                         "none — the run goes to completion. A budget "
                         "TRUNCATES the workload, so its GC totals are a "
                         "sample of the opening window, not the whole run.")
    pr.add_argument("--repeat", type=int, default=3,
                    help="runs per cell, strictly serial (default 3); the "
                         "cell's summary is the median over its valid runs")
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
    ps.add_argument("--wall-seconds", type=int, default=None,
                    help="optional per-run wall budget in seconds. Default: "
                         "none — the run goes to completion. A budget "
                         "TRUNCATES the workload, so its GC totals are a "
                         "sample of the opening window, not the whole run.")
    ps.add_argument("--repeat", type=int, default=3,
                    help="runs per cell, strictly serial (default 3); the "
                         "cell's summary is the median over its valid runs")
    ps.add_argument("--resume-dir", type=Path,
                    help="reuse an existing run-group directory")
    ps.add_argument("--dry-run", action="store_true",
                    help="print resolved paths and exit")

    pd = sub.add_parser("diff",
        help="diff per-size-class allocation tables between two run dirs")
    pd.add_argument("baseline", type=Path,
        help="baseline run directory (e.g. ..._phase2-off)")
    pd.add_argument("target", type=Path,
        help="target run directory to compare against (e.g. ..._phase2-on)")
    pd.add_argument("--variant-baseline", default=None,
        help="variant label inside baseline (auto-detected if single)")
    pd.add_argument("--variant-target", default=None,
        help="variant label inside target (auto-detected if single)")
    return p


def main():
    parser = build_parser()
    args = parser.parse_args()
    if args.list_variants:
        for n, c, _ in VARIANTS:
            print(f"  {n:<12}  {c}")
        return
    if args.cmd is None:
        parser.error("a subcommand is required: run | sweep | diff")

    # 'diff' is a pure post-processing command — no rebuild, no
    # results-root, no dry-run paths to print.
    if args.cmd == "diff":
        cmd_diff(args)
        return

    select_build_tree(args.build_tree, args.compiler_mlir)
    if getattr(args, "repeat", 1) < 1:
        parser.error("--repeat must be >= 1")
    machine, results_root = resolve_paths(args)

    if args.dry_run:
        print(json.dumps({
            "cmd": args.cmd,
            "machine": machine,
            "results_root": str(results_root),
            "wall_seconds": args.wall_seconds,
            "repeat": args.repeat,
            "build_tree": str(BUILD_TREE),
            "compiler": str(ECO_COMPILER),
            "compiler_mlir": str(ECO_COMPILER_MLIR),
            "compiler_obj": str(ECO_COMPILER_OBJ),
            "link_with": str(ECO_BOOT_NATIVE_LINK),
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
