# GC parameter sensitivity sweep — 2026-09-28

Re-run of the Sep 22 sensitivity sweep (`sensitivity-2026-09-22.json` and its
`-results.md`) against the collector as it ships after threaded-GC phases 1–7, now scored on pause
times, CPU and memory as well as wall time. Every heap key and its validation rules are listed in
[docs/options.md § Runtime: heap and GC](../../docs/options.md#runtime-heap-and-gc).

- Variants file: `plans/gc-param-sweep/sensitivity-2026-09-28.json` (59 cells)
- Results: this file, § 6 onwards
- Workload: Stage-7 self-compile, cold `eco-stuff`, run to completion (as on Sep 22)

## 1. Baseline

The baseline is the **shipped default config**: TG7d, snapshot `keep-TA2`, about 112 s wall.

`heap-profile.py` `BASELINE_HEAP` and `compiler/cmake/bootstrap/build-kernel/heap-config.json` were
regenerated on 2026-09-28 from a default-constructed `HeapConfig`. Both now list all **88** keys; before
this they held 41. Each was checked to round-trip through `applyHeapConfigJsonFile` field for field.
That check found `demote_live_fraction` being parsed as a `float` (0.3 → 0.30000001), which is now fixed
in `HeapConfigJson.cpp`. "Auto" values are written as their sentinels (thread counts 0,
`nursery_regions` 2, `nursery_region_eden_flip` −1), so the baseline resolves exactly as the shipped
binary does.

All 59 cells were checked against `validate()` with the baseline merged in. All pass, and every cell
except `legacy_nursery` resolves to the region nursery.

Regenerate both baseline files whenever a default changes in `AllocatorCommon.hpp`.

## 2. Harness

`heap-profile.py` was extended on 2026-09-28 for this sweep:

- **Timing and memory.** Each run is wrapped in GNU `time -v`, which gives CPU (user + sys) and max
  RSS for the whole process tree, and wall time.
- **Parsed from the stats banner:**
  - pause p50 / p90 / p99 / p99.9 / max and minor-only max
  - MMU at 100 / 200 / 500 ms (shorter windows read 0 % at baseline)
  - promoted MiB, tenured MB and old-gen peak
  - minors, majors and GC time
  - mutator CPU (total and outside pauses), concurrent-mark CPU, collector CPU and late minors

  A metric the binary doesn't print is left empty, never written as 0.
- **Dropped column.** The old `mutator_s = wall − major − minor` column is gone. With concurrent
  marking and tenuring it no longer measured the mutator.
- **Repeats.** `--repeat N` (default 3) runs each cell N times, strictly serially.
  - `runs_raw.tsv` holds every run. `runs.tsv` and `variants/<cell>/summary.tsv` hold the medians
    over valid runs.
  - An interrupted sweep resumes mid-cell.
- **Validity.** A run counts only if it exits with rc 0, takes no signal, and emits output
  byte-identical to the sitting's first valid run. Anything else is excluded from the medians and
  flagged.
- **Build tree.** `--build-tree build-phasetimers` links against the phase-timer runtime; the binary
  is named `eco-compiler-<mlir>-<tree>`. Lowering always uses `build/`.
- **Full rebuild.** Every tree involved gets a full `cmake --build` first, so no stale archive gets
  linked in.
- **Compiler MLIR.** `--compiler-mlir` profiles an existing compiler MLIR. The baseline MLIR is
  `snapshots/lss-loop/keep-TA2/bin/ecoTG6base.mlir` (md5 933c3ff0…), lowered once to the cached
  `build-kernel/bin/ecoTG6base.o`, as the TG6–TA experiments did.
- **No silent wipe.** A missing or stale bootstrap `eco-compiler.mlir` is now an error.
  `--bootstrap` must be passed explicitly to rebuild it, because the bootstrap path deletes
  `build/compiler/build-kernel/bin/`, which holds 46 GB of snapshot binaries.

The sweep command:

```bash
./heap-profile.py --no-prompt \
    --build-tree build-phasetimers \
    --compiler-mlir snapshots/lss-loop/keep-TA2/bin/ecoTG6base.mlir \
    sweep --variants-file plans/gc-param-sweep/sensitivity-2026-09-28.json \
    --label gc-sensitivity-2 --repeat 3
```

To resume after an interruption, add `--resume-dir heap-profiles/ws-dev-01/<timestamp>__gc-sensitivity-2`.

## 3. Protocol

- N = 3 runs per cell, run one at a time. Nothing else runs on the box, and there are no GC
  environment variables apart from `ECO_HEAP_CONFIG`.
- `baseline`, `baseline_mid` and `baseline_end` bracket the sitting, giving 9 baseline runs in total.
  Their spread sets the noise band ε of each metric: ε = max(2σ, floor), with a wall floor of 1.5 s.
  Their drift says whether the machine changed during the sitting.
- Auto thread counts resolve from the CPU mask: 16 markers, 8 minor workers and 4 background markers
  on this 24-CPU host. Don't `taskset` the runs.
- The major trigger is chaotic (see `plans/threaded-gc-07b-tenure-ageing.md` §7). The
  `major_gc_garbage_fraction` cells are a dense 0.60–0.80 sweep; never read any one of them alone.
- Budget: 59 cells × 3 runs × about 2.3 min ≈ **7 h**.

## 4. Decision model

**Scored metrics:** wall, pause p99, total CPU (user + sys), promoted MiB, max RSS.

**Explanatory only:** minors, majors, GC s, mutator and collector CPU, late %, old-gen peak. These
explain *why* a cell moved. When they and every scored metric are identical to the baseline, the key
is marked inert.

**Gates** (fail any one and the verdict is LOSS):
- The output md5 equals the baseline's.
- The run exits without a signal.
- Pause max is ≤ 1.5 × the baseline's.
- **Wall is ≤ 122 s.** This is an **absolute ceiling**: 112 s baseline + 10 s. It is a total budget,
  not a per-trade allowance. Every trade adopted during this sweep and the combination round draws
  from the same 10 s, and the final config must itself come in at ≤ 122 s.

**Exchange rates.** Positive values are *improvements*, in seconds of wall time:

```
adjusted = wall gain + pause credit + CPU credit + promotion credit − RSS penalty
```

| Term | Rate |
|---|---|
| pause credit | 2 s per 10 % lower p99 (halving p99 is worth 10 s) |
| CPU credit | 1 s per 2 s of total CPU saved |
| promotion credit | 1 s per 2.5 % less promoted (−25 % is worth 10 s) |
| RSS | 1 s per 2 % of max RSS (a penalty if higher, a credit if lower) |

A metric change smaller than its ε counts as zero. The four non-wall terms together are capped at
10 s.

**Verdicts:**
- **WIN:** wall gain > ε, and no scored metric regresses beyond its ε. Wall remains the primary aim;
  a WIN ships on its own merit.
- **TRADE:** adjusted > ε, all gates pass, and the wall stays within the remaining budget. A TRADE is
  confirmed with N = 5 before it ships.
- **INERT:** the counters and every scored metric are within ε.
- **LOSS:** everything else.

**Combination round.** WINs and TRADEs are then paired and combined, as on Sep 22, and each
combination is measured as its own cell. Single-factor results do not compose when factors share a
resource: on Sep 22 the nursery × old-gen combination came out +69 s.

## 5. Scope

**Swept** (56 cells, plus 3 baseline cells): the 11 Sep 22 keys that moved, re-centred on today's
defaults, plus the new threaded-GC keys most likely to move pauses, CPU or promotion.

**Dropped, with the reason:**
- **Inert on Sep 22, and now even more so.** Their counters were bit-identical in both directions,
  and bitmap allocation, commit-ahead and the LiveBudget trigger have landed since:
  - `mark_work_ratio` (dead code)
  - `sweep_work_budget`, `initial_sweep_budget`, `sweep_bytes_per_alloc_byte`,
    `max_sweep_bytes_per_alloc`
  - `major_gc_target_utilization`, `initial_old_gen_size`, `decommit_on_oldgen_release`
  - `small_class_heap_budget_bytes`, `small_class_cell_max_bytes`
- **Not GC:** `string_flatten_limit` and the other string/rope keys.
- **Already measured** (`plans/threaded-gc-07b-tenure-ageing.md`, `plans/threaded-gc-07-concurrent-tenuring.md`):
  - `promotion_age` 2 / 3 in region mode: +6.0 / +11.3 s, p99 28 → 46 / 71 ms.
  - `tenure_collector_threads` 4: +9 s mutator CPU.
  - `minor_fifo_order` and `tenure_fifo_order`: no retention gain; FIFO costs 25 %.
- **References and priorities, not tuning:**
  - Engine selectors: `gc_thread_mode`, `tenure_mode` 1, `conc_mark` 1, `old_gen_bitmap_alloc`.
  - Priorities: `tenure_priority`, `conc_mark_priority`. A low priority caused 9.5 s pauses.
  - Validation-only: `nursery_region_eden_flip`.

**Constraints to remember when adding cells:**
- `nursery_block_count` must be ≤ `nursery_max_block_count` (512). The old `nbc_1024` cell is now
  invalid.
- `large_object_threshold` must be a power of two in [512, 64K]. Any other value quietly drops the run
  back to the legacy nursery.
- `major_gc_initiating_occupancy` must be > `major_gc_target_utilization`.
- `alloc_buffer_size` ≤ 512K is the architectural maximum.
- `alloc_buffer_size` × `nursery_max_block_count` also sets the region stride and heap-slot count.
- Run any new cell through the § 1 `validate()` check, and confirm it still resolves
  `nursery_regions` to 1.

## 6. Results

Sitting: 2026-09-28 15:23 → 20:58 UTC. Results are in
`heap-profiles/ws-dev-01/2026-09-28T15-23-45Z__gc-sensitivity-2/`, and the scoring is
`benchmarks/gc-sweep-eval.py <that dir> --markdown`. All 59 cells completed: **177 runs, all valid**
(rc 0, no signal, output md5 `933c3ff0…`).

**Interruption.** Claude Code's memory-pressure reaper stopped the sweep after 38 cells; the machine
has 15 GB of RAM and the compiler peaks at 13.4 GB. The first resume failed every run with rc 125,
because a relative `--resume-dir` broke `time -o` under the compiler's working directory. Those rows
were removed (backups `*.bak-rc125`), the path is now resolved to an absolute one, and the second
resume ran the remaining 21 cells.

**Swapping.** Only `abuf_256K` (62–92k major faults per run) and `lgb_2.0` (32–42k) paged the heap.
Both run at about 15 GB RSS on this 15 GB machine. Their wall and max-pause losses are partly disk
time, marked `[SWAP]`. The other 57 cells stayed under 50 major faults per run.

### Noise band (9 baseline runs)

| metric | baseline median | σ | ε |
|---|---:|---:|---:|
| wall s | 110.86 | 1.04 | 2.08 |
| pause p99 ms | 28.25 | 0.62 | 1.25 (floor 1.0) |
| pause max ms | 87.2 | 4.1 | 8.3 |
| CPU s | 194.3 | 1.8 | 3.7 |
| promoted MiB | 19,862 | 0 | 100 (floor) |
| max RSS GB | 13.38 | 0.03 | **2.47** (see below) |

**The RSS band comes from the chaos cells.** All 9 baseline runs follow the same major-GC schedule,
so their RSS spread is 0.03 GB. The major trigger, though, moves the old-gen peak, and with it RSS,
by 1–3 GB on a tiny schedule change. For example, `ngrt_0.10` changed minors by 4 and its RSS rose
by 0.9 GB. The RSS ε is therefore 2σ of the per-cell medians of the `mgf_*` cells, which sweep that
trigger directly: 13.30 / 10.87 / 13.38 / 10.91 / 12.51 GB, giving ε = 2.47 GB. Without this, 11
cells were scored on schedule luck.

| drift check | wall s | p99 ms | CPU s |
|---|---:|---:|---:|
| `baseline` | 111.58 | 28.62 | 194.73 |
| `baseline_mid` | 110.75 | 27.90 | 193.50 |
| `baseline_end` | 110.86 | 27.85 | 193.33 |

No drift: the spread is 0.8 s, inside ε.

**Tally:** 0 WIN · 7 TRADE · 22 INERT · 9 FLAT · 18 LOSS (2 of them `[SWAP]`).

**Column key** for the tables below:
- Δwall: baseline − cell, so positive means faster.
- credits p/c/pr/r: the pause, CPU, promotion and RSS terms of § 4.
- ↑: the metrics that regressed beyond their ε.

### Nursery sizing and minor trigger

| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB | RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `abuf_128K` | 3/3 | 112.71 | -1.8 | 8.5 | 614.8 | 216.2 | 22414 | 11.77 | 7719 / 11 | +14.0/-11.0/-5.1/+0.0 | -2.1 | LOSS (pause-max) ↑cpu_s,promoted_MiB |
| `abuf_256K` | 3/3 | 141.12 | -30.3 | 18.6 | 1485.1 | 205.5 | 21337 | 15.06 | 3858 / 9 | +6.8/-5.6/-3.0/+0.0 | -32.0 | LOSS [SWAP] (pause-max,ceiling) ↑cpu_s,promoted_MiB,wall_s |
| `nmbc_256` | 3/3 | 108.70 | 2.2 | 14.6 | 104.7 | 196.2 | 21321 | 13.48 | 3753 / 8 | +9.6/+0.0/-2.9/+0.0 | 8.9 | TRADE ↑promoted_MiB |
| `nmbc_1024` | 3/3 | 115.08 | -4.2 | 65.0 | 129.0 | 192.0 | 17966 | 14.06 | 1030 / 7 | -26.0/+0.0/+3.8/+0.0 | -26.4 | LOSS ↑pause_p99_ms,wall_s |
| `nbc_128` | 3/3 | 112.57 | -1.7 | 27.8 | 136.8 | 195.2 | 19876 | 14.32 | 2043 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | LOSS (pause-max) |
| `nbc_512` | 3/3 | 111.14 | -0.3 | 28.4 | 111.9 | 192.8 | 19841 | 14.29 | 1867 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `ngct_0.85` | 3/3 | 110.27 | 0.6 | 24.8 | 112.4 | 193.6 | 20132 | 14.31 | 2155 / 8 | +2.5/+0.0/-0.5/+0.0 | 1.9 | LOSS ↑promoted_MiB |
| `ngct_0.99` | 3/3 | 111.26 | -0.4 | 57.6 | 119.2 | 190.0 | 19789 | 12.47 | 1847 / 7 | -20.8/+2.1/+0.0/+0.0 | -18.6 | LOSS ↑pause_p99_ms |
| `ngrt_0.10` | 3/3 | 111.36 | -0.5 | 28.5 | 111.7 | 194.0 | 19859 | 14.31 | 1920 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `ngrt_0.40` | 3/3 | 110.09 | 0.8 | 28.2 | 72.6 | 189.4 | 19827 | 11.00 | 1940 / 7 | +0.0/+2.4/+0.0/+0.0 | 2.4 | TRADE |
| `lot_4K` | 3/3 | 110.98 | -0.1 | 28.7 | 85.5 | 195.6 | 19840 | 13.37 | 1923 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `lot_16K` | 3/3 | 111.01 | -0.2 | 27.6 | 121.5 | 194.1 | 19873 | 14.33 | 1927 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `hdfs_off` | 3/3 | 113.67 | -2.8 | 38.0 | 87.0 | 207.2 | 19862 | 13.34 | 1924 / 8 | -6.9/-6.5/+0.0/+0.0 | -16.1 | LOSS ↑pause_p99_ms,cpu_s,wall_s |

### Parallel minor (TG6)

| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB | RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `minth_4` | 3/3 | 116.10 | -5.2 | 48.1 | 87.9 | 188.5 | 19862 | 13.32 | 1924 / 8 | -14.0/+2.9/+0.0/+0.0 | -16.4 | LOSS ↑pause_p99_ms,wall_s |
| `minth_12` | 3/3 | 109.27 | 1.6 | 22.0 | 82.5 | 202.0 | 19862 | 13.36 | 1924 / 8 | +4.4/-3.8/+0.0/+0.0 | 0.6 | LOSS ↑cpu_s |
| `lab_4K` | 3/3 | 111.67 | -0.8 | 29.5 | 87.1 | 198.6 | 19862 | 13.37 | 1924 / 8 | -0.9/-2.2/+0.0/+0.0 | -3.1 | LOSS ↑pause_p99_ms,cpu_s |
| `lab_32K` | 3/3 | 109.97 | 0.9 | 28.2 | 83.4 | 191.0 | 19862 | 13.33 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `mpmin_1M` | 3/3 | 110.99 | -0.1 | 28.5 | 89.0 | 195.1 | 19862 | 13.38 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `mpmin_16M` | 3/3 | 111.13 | -0.3 | 28.2 | 86.6 | 193.9 | 19862 | 13.33 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `prefetch_off` | 3/3 | 111.70 | -0.8 | 27.1 | 88.9 | 198.6 | 19862 | 13.38 | 1924 / 8 | +0.0/-2.1/+0.0/+0.0 | -2.1 | LOSS ↑cpu_s |

### Region nursery and tenuring (TG7)

| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB | RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `tcoll_2` | 3/3 | 120.89 | -10.0 | 29.2 | 128.0 | 221.3 | 19862 | 13.46 | 1924 / 8 | +0.0/-13.5/+0.0/+0.0 | -23.5 | LOSS ↑cpu_s,wall_s |
| `thelp_0` | 3/3 | 119.23 | -8.4 | 76.4 | 103.6 | 188.3 | 19862 | 13.27 | 1924 / 8 | -34.1/+3.0/+0.0/+0.0 | -39.5 | LOSS ↑pause_p99_ms,wall_s |
| `thelpth_1` | 3/3 | 118.66 | -7.8 | 75.4 | 105.8 | 187.7 | 19862 | 13.27 | 1924 / 8 | -33.4/+3.3/+0.0/+0.0 | -37.9 | LOSS ↑pause_p99_ms,wall_s |
| `shadow_16` | 3/3 | 109.43 | 1.4 | 25.7 | 83.8 | 188.8 | 19862 | 13.19 | 1924 / 8 | +1.8/+2.8/+0.0/+0.0 | 4.6 | TRADE |

### Large pointer objects / YLOS (TG4b)

| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB | RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `lpmax_32K` | 3/3 | 111.69 | -0.8 | 28.0 | 85.6 | 194.8 | 19862 | 13.33 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `lpmax_512K` | 3/3 | 110.02 | 0.8 | 28.5 | 85.9 | 193.7 | 19862 | 13.37 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `lpdiv_4` | 3/3 | 110.15 | 0.7 | 28.7 | 88.0 | 194.8 | 19862 | 13.38 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `lpdiv_16` | 3/3 | 110.93 | -0.1 | 28.1 | 86.7 | 195.5 | 19862 | 13.37 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |

### Major-GC triggers (TG2, TG5c)

| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB | RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `mio_0.90` | 3/3 | 110.43 | 0.4 | 28.3 | 87.2 | 193.7 | 19862 | 13.38 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `mgf_0.60` | 3/3 | 110.07 | 0.8 | 28.2 | 79.1 | 196.3 | 19862 | 13.30 | 1924 / 9 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `mgf_0.65` | 3/3 | 109.72 | 1.1 | 27.3 | 90.6 | 190.6 | 19862 | 10.87 | 1924 / 8 | +0.0/+1.8/+0.0/+9.4 | 10.0 | TRADE |
| `mgf_0.75` | 3/3 | 109.28 | 1.6 | 27.7 | 90.1 | 189.4 | 19862 | 10.91 | 1924 / 7 | +0.0/+2.5/+0.0/+0.0 | 2.5 | TRADE |
| `mgf_0.80` | 3/3 | 109.59 | 1.3 | 27.7 | 77.8 | 190.7 | 19862 | 12.51 | 1924 / 6 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `lb_3.0` | 3/3 | 111.12 | -0.3 | 29.1 | 86.9 | 193.8 | 19862 | 10.80 | 1924 / 10 | +0.0/+0.0/+0.0/+9.6 | 9.6 | TRADE |
| `lb_6.0` | 3/3 | 110.64 | 0.2 | 27.8 | 94.2 | 194.2 | 19862 | 13.45 | 1924 / 7 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `lgb_1.25` | 3/3 | 110.16 | 0.7 | 27.2 | 87.1 | 194.8 | 19862 | 10.30 | 1924 / 9 | +0.0/+0.0/+0.0/+11.5 | 10.0 | TRADE |
| `lgb_2.0` | 3/3 | 118.86 | -8.0 | 31.1 | 1506.5 | 200.6 | 19862 | 14.93 | 1924 / 7 | -2.0/-3.2/+0.0/+0.0 | -13.2 | LOSS [SWAP] (pause-max) ↑pause_p99_ms,cpu_s,wall_s |
| `hroom_0` | 3/3 | 111.89 | -1.0 | 28.7 | 88.6 | 194.5 | 19862 | 13.33 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `hroom_3.0` | 3/3 | 110.61 | 0.2 | 27.9 | 84.4 | 194.1 | 19862 | 13.37 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `demote_0.15` | 3/3 | 109.88 | 1.0 | 28.0 | 89.3 | 191.1 | 19862 | 12.96 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `demote_0.5` | 3/3 | 110.93 | -0.1 | 28.9 | 113.2 | 194.7 | 19862 | 13.52 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `gdcap_2` | 3/3 | 111.32 | -0.5 | 28.2 | 88.8 | 195.1 | 19862 | 13.37 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |

### Marking (TG5a-c)

| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB | RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `markth_8` | 3/3 | 110.21 | 0.7 | 28.1 | 86.1 | 193.4 | 19862 | 13.37 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `markth_24` | 3/3 | 110.54 | 0.3 | 28.7 | 86.9 | 193.8 | 19862 | 13.34 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `cmth_2` | 3/3 | 111.45 | -0.6 | 28.7 | 87.8 | 195.0 | 19862 | 13.38 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `cmth_8` | 3/3 | 110.39 | 0.5 | 28.5 | 86.1 | 195.1 | 19862 | 13.33 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `lag_4` | 3/3 | 110.69 | 0.2 | 28.1 | 85.9 | 194.5 | 19862 | 13.37 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `lag_32` | 3/3 | 111.61 | -0.8 | 28.3 | 87.2 | 194.0 | 19862 | 13.33 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `slices_16` | 3/3 | 110.47 | 0.4 | 26.9 | 87.9 | 193.0 | 19862 | 13.36 | 1924 / 7 | +1.0/+0.0/+0.0/+0.0 | 1.0 | FLAT |
| `slices_64` | 3/3 | 110.26 | 0.6 | 28.4 | 72.1 | 193.8 | 19862 | 14.35 | 1924 / 9 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `concmark_0` | 3/3 | 112.93 | -2.1 | 39.6 | 86.7 | 202.1 | 19862 | 13.37 | 1924 / 8 | -8.1/-3.9/+0.0/+0.0 | -11.9 | LOSS ↑pause_p99_ms,cpu_s |

### Commit and decommit (TG3)

| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB | RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `cahead_0` | 3/3 | 113.37 | -2.5 | 30.4 | 89.2 | 200.9 | 19862 | 13.18 | 1924 / 8 | -1.5/-3.3/+0.0/+0.0 | -7.3 | LOSS ↑pause_p99_ms,cpu_s,wall_s |
| `cahead_512M` | 3/3 | 111.22 | -0.4 | 27.9 | 87.7 | 195.8 | 19862 | 13.77 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `ddm_0` | 3/3 | 110.13 | 0.7 | 27.9 | 83.7 | 192.3 | 19862 | 13.33 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `ddm_3` | 3/3 | 111.14 | -0.3 | 28.2 | 86.3 | 194.8 | 19862 | 13.38 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |

### Reference arm

| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB | RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `legacy_nursery` | 3/3 | 120.96 | -10.1 | 33.8 | 132.3 | 197.7 | 19862 | 12.43 | 1924 / 8 | -4.0/+0.0/+0.0/+0.0 | -14.1 | LOSS (pause-max) ↑pause_p99_ms,wall_s |

## 7. Reading the results

**TRADE candidates.** None of them costs wall time beyond the noise band: the slowest is `lb_3.0`
at 111.1 s, against 110.9 s for the baseline. The 10 s budget is untouched.

| cell | what it buys | cost | confidence |
|---|---|---|---|
| `nmbc_256` | p99 28.2 → **14.6 ms** (−48 %), wall −2.2 s (just past ε) | promoted +7 %, minors ×2, max pause 105 ms (+20 %, inside the gate) | **High.** Minor pause length tracks nursery size in both directions (`nmbc_1024`: p99 65 ms). |
| `shadow_16` | CPU −5.5 s, p99 −9 %, wall −1.4 s | none measured | **High.** GC counters identical to baseline, so this is not schedule chaos. A cheaper shadow map. |
| `lgb_1.25` | RSS −3.1 GB (10.30, below every `mgf` cell) | +1 major | **Medium.** A tighter LiveBudget growth bound means more majors and a lower peak. Needs a gf sweep. |
| `lb_3.0` | RSS −2.6 GB | +2 majors | **Medium.** Same mechanism as `lgb_1.25`, same caveat. |
| `ngrt_0.40` | CPU −4.9 s, max pause 73 ms | RSS −2.4 GB sits just inside ε | **Low.** It moved the schedule (7 majors); likely chaos. |
| `mgf_0.65`, `mgf_0.75` | RSS or CPU | none | **Not adoptable.** These are the chaos reference cells; their credits are schedule luck by construction. |

**`abuf_128K`: the biggest pause result, but blocked.**
- Minor pauses: p99 **7 ms** and max 75–94 ms, against 28 / 87 ms at baseline.
- The pause-max gate failure (146 ms – 1.5 s) comes entirely from **concurrent-mark in-pause
  slices**. The baseline has none; the 1.5 s pause in r3 is a single "minor + mark slice".
- It also costs CPU +22 s and promoted +13 %.

> **Corrected by the second sweep (§ 10).** The first reading blamed the step-counted
> `conc_mark_assist_lag` expiring 4× sooner with 4× the minors. `nmbc_128` refutes that: it runs as
> many minors (7,538), has the same minor p99 (7 ms) and also takes mark slices, but its slices
> stay bounded (max 21–72 ms). It pays only +6.5 s CPU and runs 8 majors, not 11. The outliers and
> the CPU cost belong to the **128K old-gen page size** (`alloc_buffer_size` is also the BBoP page),
> not to minor frequency. The `abuf_128K` + lag combinations are dropped.

**Defaults the sweep confirms** (each alternative loses):
- `gc_minor_threads` auto (8): 4 is +5.2 s with p99 48 ms; 12 is −1.6 s but CPU +7.7 s, a net LOSS.
- `tenure_help` 1 and `tenure_help_threads` 0: turning either off means p99 75 ms and +8 s.
- `tenure_collector_threads` 1: 2 is +10 s wall and +27 s CPU.
- `conc_mark` 2: in-pause marking (0) is +2.1 s with p99 40 ms.
- `use_hybrid_dfs`: off is +2.8 s and CPU +13 s.
- `commit_ahead_bytes` 128M: 0 is +2.5 s and CPU +6.6 s.
- The region nursery: legacy is **+10.1 s**.
- `nursery_max_block_count` 512: 1024 is +4.2 s with p99 65 ms.
- `nursery_gc_threshold` 0.95: 0.99 doubles p99.

**Inert** (counters and scored metrics within ε), so these keys can be dropped from future sweeps:
- `mark` threads 8 / 24 and `conc_mark_threads` 2 / 8. Marking isn't on the critical path at
  8 majors.
- `conc_mark_assist_lag` at this nursery size.
- `minor_lab_bytes` 32K and `minor_parallel_min_bytes`.
- `large_ptr_nursery_*`.
- `mio_0.90`, `major_gc_headroom_margin` 0 / 3, `demote_live_fraction`, `garbage_denom_cap`.
- `decommit_delay_majors`, `commit_ahead_bytes` 512M.

## 8. Combination round

This was proposed after the first sweep and revised after the second (§ 10). Variants are in
`plans/gc-param-sweep/combinations-2026-09-29.json`: 19 cells at N = 3, and results are in § 11.

**Dropped from the first proposal:**
- C2 and C3 (`abuf_128K` + assist lag): their premise was refuted by `nmbc_128`.
- C1 grew into a sweep across the nursery frontier.

| group | cells | question |
|---|---|---|
| Frontier × granule | `n192_s16`, `n256_s16`, `n384_s16` | Does `shadow_16`'s CPU saving stack on each nursery point of the pause/wall curve? |
| + strings | `n192_s16_sfl`, `n256_s16_sfl`, `n384_s16_sfl` | Does `string_flatten_limit` 128K add its −1.3 s on top? |
| RSS pair | `n256_s16_{lgb1.25,lb3.0}_gf{0.65,0.70,0.75}` | Does the −3 GB RSS survive at every trigger point? |
| RSS references | `n256_s16_gf{0.65,0.75}`, `base_gf{0.65,0.75}` | same-sitting RSS at each gf, without the LiveBudget change |
| drift | `baseline`, `baseline_mid`, `baseline_end` | 9 reference runs |

The final candidate is confirmed at N = 5 against the baseline at N = 5 (§ 4) before any default
changes.

## 9. Outcome

Across four sittings (two sweeps, a combination round and an N = 5 confirmation; 112 cells, 344 runs, all valid):

- **No single key is a WIN.** The shipped defaults sit at or near the wall optimum for every key,
  taken alone. Every nursery change raises promotion, which blocks the WIN verdict.
- **The combination is a clear TRADE:** a 192 MiB nursery ceiling + 16-byte shadow granule +
  128K string flatten limit + LiveBudget 3.0. At N = 5 it gives wall −4.5 s (110.7 → 106.3),
  CPU −7.3 s, p99 −35 %, RSS −19 %, and an unchanged max pause (§ 12).
- **Wall budget used:** 0 of 10 s. Every candidate is faster than baseline.
- **Default changes: none yet.** § 12 lists the ship gates, starting with the 16-byte granule's
  small-object safety.
- **Knowledge gained:**
  - Minor pause length is set by the nursery ceiling (p99 8 → 65 ms from 64 → 512 MiB).
  - The only deterministic RSS lever is `major_gc_live_budget`.
  - `abuf_128K`'s pause outliers come from the old-gen page size, not minor frequency.
  - The GlobalPressure and heap-size ceilings don't bind.
  - The mark-pacing, placement and most trigger keys are inert on this workload.
- **Harness fixes made along the way:**
  - Absolute `--resume-dir`.
  - A refusal to start while an orphaned compiler is running.
  - Swap detection in the scorer.
  - The chaos-derived RSS band.

## 10. Second sweep: keys not covered by the first

Variants: `plans/gc-param-sweep/sensitivity2-2026-09-28.json` (27 cells + 3 baselines). Results:
`heap-profiles/ws-dev-01/2026-09-28T22-28-02Z__gc-sensitivity-3/`. Sitting 2026-09-28 22:28 →
2026-09-29 01:14 UTC. **90 runs, all valid**, and no run above 10k major faults (worst 5.8k).

Scored with `gc-sweep-eval.py <dir> --markdown --rss-eps 2.47`. This sitting has no `mgf_*` cells,
so the RSS band is carried over from § 6. Baseline (9 runs): wall 110.70 s (ε 1.50, the floor),
p99 28.43 ms, max 86.9 ms, CPU 194.6 s, RSS 13.38 GB. Drift: 110.70 / 111.51 / 110.37 s, which is
consistent with the first sitting (110.86 s).

**Tally:** 0 WIN · 3 TRADE · 16 INERT · 6 FLAT · 2 LOSS.

**Not swept, by reading:** `rope_max_height`, `rope_leaf_count_limit` and `rope_min_leaf_size` only
feed an `if` whose body is `// TODO: rebalance` (`StringOps.cpp:267-272`). They cannot change
anything.

| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB | RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `nmbc_128` | 3/3 | 111.27 | -0.6 | 8.4 | 108.8 | 201.1 | 22398 | 12.06 | 7538 / 8 | +14.1/-3.3/-5.1/+0.0 | 5.7 | TRADE ↑cpu_s,promoted_MiB |
| `nmbc_192` | 3/3 | 111.44 | -0.7 | 10.2 | 67.9 | 196.3 | 21682 | 14.96 | 5009 / 7 | +12.8/+0.0/-3.7/+0.0 | 9.2 | TRADE ↑promoted_MiB |
| `nmbc_384` | 3/3 | 107.98 | 2.7 | 19.5 | 83.2 | 193.1 | 20536 | 13.44 | 2529 / 8 | +6.3/+0.0/-1.4/+0.0 | 7.6 | TRADE ↑promoted_MiB |
| `gpf_0.55` | 3/3 | 110.31 | 0.4 | 28.3 | 84.5 | 194.5 | 19862 | 13.32 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `gpf_0.60` | 3/3 | 110.48 | 0.2 | 28.3 | 87.3 | 193.3 | 19862 | 13.33 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `gpf_0.65` | 3/3 | 110.77 | -0.1 | 28.5 | 87.1 | 195.9 | 19862 | 13.38 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `mhs_18G` | 3/3 | 111.02 | -0.3 | 27.6 | 86.3 | 194.7 | 19862 | 13.38 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `mhs_20G` | 3/3 | 110.51 | 0.2 | 27.9 | 84.5 | 193.5 | 19862 | 13.33 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `impg_1.0` | 3/3 | 110.74 | -0.0 | 28.4 | 85.9 | 193.9 | 19862 | 13.34 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `impg_2.0` | 3/3 | 111.17 | -0.5 | 28.4 | 86.3 | 194.5 | 19862 | 13.38 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `imff_0.90` | 3/3 | 111.07 | -0.4 | 28.2 | 86.7 | 194.4 | 19862 | 13.38 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `imff_1.0` | 3/3 | 110.07 | 0.6 | 28.2 | 84.2 | 194.7 | 19862 | 13.38 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `imsu_4096` | 3/3 | 111.29 | -0.6 | 28.8 | 87.6 | 195.7 | 19862 | 13.34 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `imsu_65536` | 3/3 | 110.64 | 0.1 | 28.7 | 88.4 | 195.2 | 19862 | 13.33 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `sfl_8K` | 3/3 | 117.03 | -6.3 | 29.0 | 84.2 | 200.9 | 20195 | 13.35 | 1934 / 8 | +0.0/-3.2/-0.7/+0.0 | -10.2 | LOSS ↑cpu_s,promoted_MiB,wall_s |
| `sfl_128K` | 3/3 | 109.38 | 1.3 | 28.4 | 86.4 | 192.8 | 19645 | 13.39 | 1918 / 8 | +0.0/+0.0/+0.4/+0.0 | 0.4 | FLAT |
| `tiny_32` | 3/3 | 111.98 | -1.3 | 26.7 | 141.0 | 195.0 | 19842 | 14.28 | 1925 / 8 | +1.2/+0.0/+0.0/+0.0 | 1.2 | LOSS (pause-max) |
| `tiny_512` | 3/3 | 111.14 | -0.4 | 28.2 | 88.9 | 196.0 | 19861 | 13.38 | 1925 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `u8view_16` | 3/3 | 110.87 | -0.2 | 28.5 | 87.6 | 195.0 | 19862 | 13.36 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `u8view_128` | 3/3 | 110.26 | 0.4 | 28.3 | 82.9 | 192.4 | 19862 | 13.32 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `utf8_off` | 3/3 | 109.77 | 0.9 | 28.5 | 78.9 | 192.8 | 19926 | 12.52 | 1945 / 7 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `lot_2K` | 3/3 | 110.25 | 0.5 | 28.0 | 80.8 | 192.6 | 19833 | 13.32 | 1923 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `lot_32K` | 3/3 | 111.42 | -0.7 | 27.5 | 89.8 | 192.8 | 19901 | 14.37 | 1929 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `lot_64K` | 3/3 | 111.07 | -0.4 | 27.1 | 84.5 | 193.4 | 19903 | 14.37 | 1929 / 8 | +0.9/+0.0/+0.0/+0.0 | 0.9 | FLAT |
| `lpdiv_0` | 3/3 | 111.64 | -0.9 | 27.9 | 87.2 | 195.3 | 19862 | 13.37 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `lpdiv_2` | 3/3 | 111.51 | -0.8 | 28.0 | 84.9 | 196.1 | 19862 | 13.37 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `lpmax_0` | 3/3 | 110.29 | 0.4 | 28.3 | 86.8 | 194.0 | 19862 | 13.37 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |

### 10.1 Reading the second sweep

**The nursery-ceiling curve, both sittings** (512 = the default):

| ceiling (blocks / MiB) | minors | wall s | p99 ms | max ms | CPU s | promoted GiB | majors |
|---|---:|---:|---:|---:|---:|---:|---:|
| 128 / 64 | 7,538 | 111.3 | **8.4** | 108.8 | 201.1 | 21.9 | 8 |
| 192 / 96 | 5,009 | 111.4 | **10.2** | **67.9** | 196.3 | 21.2 | 7 |
| 256 / 128 | 3,753 | **108.7** | 14.6 | 104.7 | 196.2 | 20.8 | 8 |
| 384 / 192 | 2,529 | **108.0** | 19.5 | 83.2 | 193.1 | 20.1 | 8 |
| 512 / 256 (default) | 1,924 | 110.9 | 28.2 | 87.2 | 194.3 | 19.4 | 8 |
| 1024 / 512 | 1,030 | 115.1 | 65.0 | 129.0 | 192.0 | 17.5 | 7 |

- **p99 is monotone in the ceiling:** 8 → 10 → 15 → 20 → 28 → 65 ms.
- **Wall has a shallow optimum at 128–192 MiB,** 2–3 s under the default. Both ends lose: below
  96 MiB on CPU, at 512 MiB on pause length and wall.
- **Promotion rises steadily as the nursery shrinks** (+3.4 % at 192 MiB, +12.8 % at 64 MiB).
  Objects get less time to die. This promotion cost is the only thing that keeps every point off
  WIN.
- **`nmbc_192` has the lowest max pause of any cell in either sweep** (67.9 ms, against 87 ms at
  baseline), and p99 10 ms. Its RSS of 14.96 GB is a 7-major schedule: chaos, inside ε.

**Memory ceilings don't bind.** `gpf` 0.55 / 0.60 / 0.65 and `max_heap_size` 18G / 20G all have GC
counters identical to baseline. Even at gpf 0.55, the GlobalPressure trigger (11 GB) never fires
before LiveBudget does, and an 18G heap (14 GB cap) keeps the occupancy trigger above the 11.95 GB
peak. **The only RSS levers are the LiveBudget pair** (`lgb_1.25`, `lb_3.0`, § 7), and those are
tested across gf in the combination round.

**Incremental-mark pacing** (`impg`, `imff`, `imsu`): inert. Marking is not on the critical path
at 8 majors.

**Strings:**
- **`string_flatten_limit` 8K loses** (+6.3 s, CPU +6.3 s, promoted +1.7 %): more ropes survive,
  and consumers flatten them repeatedly.
- **128K is FLAT-positive:** −1.3 s (just inside ε), CPU −1.8 s, promoted −1.1 %. The direction is
  consistent (8K: +6.3, 32K: 0, 128K: −1.3), so it goes into the combination round.
- `string_tiny_slice_limit` 32 fails the pause-max gate (141 ms); 512 is flat.
- `utf8_view_min_len`: inert (it only affects Bytes decoding).
- **`utf8_strings_enabled=false` is FLAT** (−0.9 s, CPU −1.8 s, RSS −0.9 GB; the RSS change is a
  7-major schedule). UTF-8 strings buy nothing measurable on this workload. That's a neutral result:
  it means UTF-8 costs nothing, not that turning it off helps.

**Large objects:** `large_object_threshold` 2K / 32K / 64K are flat (32K and 64K land on a
worse-RSS schedule, inside ε). `large_ptr_nursery_divisor` 0 / 2 and `large_ptr_nursery_max_size` 0
are inert. On this workload, large-object placement doesn't matter.

## 11. Combination round: results

Variants: `plans/gc-param-sweep/combinations-2026-09-29.json`. Results:
`heap-profiles/ws-dev-01/2026-09-29T01-16-39Z__gc-combinations-2/`. **57 runs, all valid**, and no
run above 10k major faults (worst 3.6k).

**Interruption.** The memory-pressure reaper killed the harness after 10 runs. It left the compiler
child of `n192_s16` r2 running as an orphan, which would have contaminated a resume. The orphan was
stopped, and the harness now refuses to start a run while another instance of its binary is running
(`_pids_running`, matched by `/proc/<pid>/exe`). The resume then completed the round.

Scored with `--rss-eps 2.47`. Baseline (9 runs): wall 109.97 s (ε 1.89), p99 27.94 ms, max 85.0 ms,
CPU 192.7 s, RSS 13.33 GB. Drift 109.65 / 111.68 / 109.97 s.

| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB | RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `base_gf0.65` | 3/3 | 109.87 | 0.1 | 27.2 | 91.0 | 189.7 | 19862 | 10.87 | 1924 / 8 | +0.0/+0.0/+0.0/+0.0 | 0.0 | INERT |
| `base_gf0.75` | 3/3 | 110.27 | -0.3 | 28.2 | 94.5 | 190.9 | 19862 | 10.91 | 1924 / 7 | +0.0/+0.0/+0.0/+0.0 | 0.0 | FLAT |
| `n192_s16` | 3/3 | 110.05 | -0.1 | 9.9 | 71.8 | 193.4 | 21682 | 14.88 | 5009 / 7 | +12.9/+0.0/-3.7/+0.0 | 9.3 | TRADE ↑promoted_MiB |
| `n256_s16` | 3/3 | 107.48 | 2.5 | 13.6 | 101.5 | 191.0 | 21321 | 13.41 | 3753 / 8 | +10.2/+0.0/-2.9/+0.0 | 9.8 | TRADE ↑promoted_MiB |
| `n384_s16` | 3/3 | 107.10 | 2.9 | 18.8 | 91.7 | 186.6 | 20536 | 13.00 | 2529 / 8 | +6.5/+3.0/-1.4/+0.0 | 11.1 | TRADE ↑promoted_MiB |
| `n192_s16_sfl` | 3/3 | 107.27 | 2.7 | 9.3 | 71.2 | 189.9 | 21468 | 14.96 | 4993 / 7 | +13.3/+0.0/-3.2/+0.0 | 12.7 | TRADE ↑promoted_MiB |
| `n256_s16_sfl` | 3/3 | 106.42 | 3.5 | 13.4 | 106.3 | 189.9 | 21107 | 13.41 | 3742 / 8 | +10.4/+0.0/-2.5/+0.0 | 11.5 | TRADE ↑promoted_MiB |
| `n384_s16_sfl` | 3/3 | 105.46 | 4.5 | 18.1 | 95.6 | 185.6 | 20320 | 12.99 | 2521 / 8 | +7.0/+3.5/-0.9/+0.0 | 14.2 | TRADE ↑promoted_MiB |
| `n256_s16_gf0.65` | 3/3 | 107.23 | 2.7 | 13.3 | 63.4 | 188.6 | 21321 | 13.02 | 3753 / 8 | +10.5/+2.0/-2.9/+0.0 | 12.3 | TRADE ↑promoted_MiB |
| `n256_s16_gf0.75` | 3/3 | 107.28 | 2.7 | 13.4 | 96.7 | 188.5 | 21321 | 10.97 | 3753 / 7 | +10.4/+2.1/-2.9/+0.0 | 12.2 | TRADE ↑promoted_MiB |
| `n256_s16_lgb1.25_gf0.65` | 3/3 | 108.08 | 1.9 | 13.7 | 95.9 | 191.0 | 21321 | 10.96 | 3753 / 9 | +10.2/+0.0/-2.9/+0.0 | 7.3 | TRADE ↑promoted_MiB |
| `n256_s16_lgb1.25_gf0.7` | 3/3 | 107.23 | 2.7 | 13.6 | 55.8 | 190.8 | 21321 | 14.72 | 3753 / 8 | +10.2/+0.0/-2.9/+0.0 | 10.0 | TRADE ↑promoted_MiB |
| `n256_s16_lgb1.25_gf0.75` | 3/3 | 107.63 | 2.3 | 13.7 | 72.2 | 188.4 | 21321 | 11.11 | 3753 / 7 | +10.2/+2.1/-2.9/+0.0 | 11.8 | TRADE ↑promoted_MiB |
| `n256_s16_lb3.0_gf0.65` | 3/3 | 108.42 | 1.5 | 14.4 | 113.2 | 194.7 | 21321 | 9.50 | 3753 / 12 | +9.7/+0.0/-2.9/+14.4 | 10.0 | TRADE ↑promoted_MiB |
| `n256_s16_lb3.0_gf0.7` | 3/3 | 108.28 | 1.7 | 14.4 | 93.3 | 192.3 | 21321 | 9.27 | 3753 / 11 | +9.7/+0.0/-2.9/+15.2 | 10.0 | TRADE ↑promoted_MiB |
| `n256_s16_lb3.0_gf0.75` | 3/3 | 108.29 | 1.7 | 14.9 | 118.9 | 193.8 | 21321 | 9.48 | 3753 / 10 | +9.3/+0.0/-2.9/+14.4 | 10.0 | TRADE ↑promoted_MiB |

### 11.1 Reading the combination round

**The frontier gains stack.** At every nursery point, `shadow_16` and then `string_flatten_limit`
128K each improve wall and CPU:

| nursery | alone (§ 10) | + `shadow_16` | + `sfl` 128K | p99 ms | max ms | CPU s | promoted |
|---|---:|---:|---:|---:|---:|---:|---:|
| 192 | 111.4 | 110.1 | **107.3** | **9.3** | **71** | 189.9 | +8.1 % |
| 256 | 108.7 | 107.5 | **106.4** | 13.4 | 106 | 189.9 | +6.3 % |
| 384 | 108.0 | 107.1 | **105.5** | 18.1 | 96 | **185.6** | +2.3 % |

(The "alone" figures come from other sittings; each sitting's baseline is about 110 s.)

**RSS pair across the trigger**, against the lead `n256_s16` at the same gf:

| gf | lead | + `lgb_1.25` | + `lb_3.0` | lead majors → `lb_3.0` majors |
|---|---:|---:|---:|---:|
| 0.65 | 13.02 GB | 10.96 | **9.50** | 8 → 12 |
| 0.70 | 13.41 GB | **14.72** | **9.27** | 8 → 11 |
| 0.75 | 10.97 GB | 11.11 | **9.48** | 7 → 10 |

- **`live_growth_bound` 1.25 is rejected.** Its RSS moves with the trigger: 2 GB better at one gf
  point, 1.3 GB worse at the next.
- **`major_gc_live_budget` 3.0 is robust.** It gives 9.3–9.5 GB at every gf point, 1.5–4.1 GB below
  the lead, for about +1 s wall, +3–4 s CPU, 10–12 majors and max pauses of 93–119 ms (inside the
  1.5 × gate). This is the only deterministic RSS lever in all three rounds. It changes how much
  allocation a major waits for, not the chaotic garbage-fraction arithmetic.

**Every nursery combination is a TRADE, none a WIN.** Each one raises promotion beyond its 100 MiB
band. The adjusted scores: `n384_s16_sfl` 14.2, `n192_s16_sfl` 12.7, `n256_s16_sfl` 11.5.

**Carried to the N = 5 confirmation** (`plans/gc-param-sweep/confirm-2026-09-29.json`):
- `n384_s16_sfl`: best wall, CPU and adjusted score.
- `n256_s16_sfl`: halves p99.
- `n384_s16_sfl` + `lb_3.0`: the memory variant, measured here for the first time.
- `baseline`, all at N = 5.

`n192_s16_sfl` has the best pauses but was left out: RSS 14.96 GB on a 15 GB machine, and one
`n192_s16` run took 3.6k major faults. It is next in line if pause is to lead.

## 12. N = 5 confirmation

Variants: `plans/gc-param-sweep/confirm-2026-09-29.json`. Results:
`heap-profiles/ws-dev-01/2026-09-29T03-01-15Z__gc-confirm-5/`. **20 runs, all valid, 0 major faults.**
Baseline (5 runs): wall 110.72 s (sd 0.53, ε 1.5), p99 28.50 ms, max 84.4 ms, CPU 195.0 s, RSS
13.34 GB.

| cell | valid | wall s | Δwall | p99 ms | max ms | CPU s | promoted MiB | RSS GB | minors / majors | credits p/c/pr/r | adjusted | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `n384_s16_sfl` | 5/5 | 106.77 | 4.0 | 18.0 | 96.6 | 187.0 | 20320 | 13.00 | 2521 / 8 | +7.4/+4.0/-0.9/+0.0 | 14.0 | TRADE ↑promoted_MiB |
| `n256_s16_sfl` | 5/5 | 106.05 | 4.7 | 13.6 | 103.9 | 190.2 | 21107 | 13.40 | 3742 / 8 | +10.5/+2.4/-2.5/+0.0 | 14.7 | TRADE ↑promoted_MiB |
| `n384_s16_sfl_lb3.0` | 5/5 | 106.27 | 4.5 | 18.4 | 84.7 | 187.7 | 20320 | 10.87 | 2521 / 10 | +7.1/+3.6/-0.9/+0.0 | 14.2 | TRADE ↑promoted_MiB |

**All three candidates confirm at N = 5.**
- Every one is 4.0–4.7 s faster than baseline, beyond ε in each of the 5 runs. The slowest
  candidate run (107.44 s) beats the fastest baseline run (110.63 s).
- The three candidates' adjusted scores (14.0 / 14.7 / 14.2) are within noise of one another, so
  the choice comes down to which secondary metric matters most:

| priority | pick | why |
|---|---|---|
| pause p99 | `n256_s16_sfl` | p99 13.6 ms (−52 %), wall −4.7 s. Costs: max pause +23 % (104 ms, inside the gate), promoted +6.3 %. |
| memory, and max pause | **`n384_s16_sfl_lb3.0`** | RSS **10.87 GB (−19 %)**, max pause **unchanged** (84.7 ms), CPU −7.3 s, wall −4.5 s, p99 −35 %. Its only regression is promoted +2.3 %. |
| CPU | `n384_s16_sfl` | CPU −8.0 s. Otherwise dominated by the `lb3.0` variant. |

**The recommended default is `n384_s16_sfl_lb3.0`:**

```json
{"nursery_max_block_count": 384, "shadow_granule_log2": 4,
 "string_flatten_limit": "128K", "major_gc_live_budget": 3.0}
```

Among the three, it is the only candidate that regresses nothing beyond promotion. It also removes
the memory pressure that killed two of these sittings on this 15 GB machine. The scorer gives its
RSS gain zero credit: at −2.47 GB it sits exactly on the chaos-derived ε. But § 11 showed `lb_3.0`'s
RSS is flat across gf 0.65–0.75, so the gain is not schedule luck. `n256_s16_sfl` is the alternative
if p99 matters more than memory.

**Gates before any of this ships:**
1. **`shadow_granule_log2 = 4` safety.** A survivor under 16 B aborts the region nursery. Run the E2E
   and stress suites (validate build included) with the candidate config, and audit object sizes
   per tag (plan 07 Step 0 item 9 did a census, not an audit). If a small object is possible, drop
   `shadow_16`; it is worth about 1 s and 3–5 s CPU.
2. **A second workload.** Everything here is the self-compile.
3. **A Release (no-stats) build** measurement of baseline vs candidate, since users run that build.
4. **Change the defaults in `AllocatorCommon.hpp`**, then regenerate `BASELINE_HEAP` and
   `heap-config.json` (§ 1). Any default change invalidates both.

## 13. Defaults changed (2026-09-29)

The user asked for the § 12 recommendation to become the shipped default. **Two of its four keys
failed the test gate and were reverted.** What ships:

| key | old | shipped | status |
|---|---|---|---|
| `nursery_max_block_count` | 512 | **384** | shipped |
| `string_flatten_limit` | 32K | **128K** | shipped |
| `shadow_granule_log2` | 3 | 3 | **reverted: unsafe** |
| `major_gc_live_budget` | 4.5 | 4.5 | **reverted: open bug** |

### 13.1 Gate findings

1. **`shadow_granule_log2 = 4` aborts real programs.** Under the gc-pressure config,
   `stress-elm/BytesRoundtripNestedBytes` keeps an **8-byte, header-only** survivor alive (tag not identified: the message's trailing `0` is an unused argument, not the tag; see `/work/2-gc-bugs.md`):
   `[gc] FATAL: region nursery: a survivor under 16 B with a 16-byte shadow granule (… 8 0)`. The
   self-compile never had one (0 in every banner), which is why E12 and both sweeps called it
   admissible. It stays at 3. Making 4 safe needs either a 16-byte minimum object size or a region
   nursery that falls back to 8-byte granules; neither is a tuning change.
2. **`major_gc_live_budget = 3.0` fails two validate-build tests.** They pass at 4.5 with everything
   else unchanged; bisected across the four keys, 3.0 alone reproduces both.
   - `threaded-gc-07: E2 … modes 1 and 2 agree` (`ConcurrentTenureTest.cpp:174`): the child hits
     the **HEAP_044 assertion in `OldGenSpace::scanObject`**. A `Tag_Custom` of size 0 is marked,
     but `MinorWorkload` allocates only 5-field customs. The marker is reading something that is
     not a valid object. The earlier LiveBudget majors (concurrent cycles overlapping tenure jobs)
     expose it.
   - `threaded-gc-05b: negative control — skipping marker 1's accumulator is caught`
     (`ParallelMarkTest.cpp:625`): the planted fault is no longer caught. This is likely the
     changed major schedule hiding the fault, and needs checking alongside the first.

   HEAP_057 calls every k policy-safe, so the first failure is a **bug to root-cause**, recorded as
   OPEN in HEAP_057. k stays 4.5 until it is fixed. The self-compile at k = 3.0 was output-identical
   in all 11 runs, but the validate build is the arbiter.
3. **A unit test encoded the old flatten limit.** `StringOpsTest.cpp` "append over FLATTEN_LIMIT
   builds a rope" hard-coded 20000-unit halves. It now sizes them from the config. The failure
   showed only as a RapidCheck "Falsifiable" line: **`Tests failed: 0` did not count it.**
4. **Three Elm E2E tests** built strings just over 32768 to reach the rope path. They now build
   140000 units, so rope coverage is kept (§ 13 file list).

### 13.2 Gate on the shipped config (all green)

| step | result |
|---|---|
| `build` `--target full` (before the reverts) | 1946/1946 plus the one RapidCheck property fixed above |
| `build` `--target check` | 1946/1946 |
| `build` stress: default, gc-pressure, gc-pressure-parallel | 101/101 each |
| `build-validate` `--target check` | 1947/1947 |
| `build-validate` stress, gc-pressure | 101/101 |
| full bootstrap (`ECO_MONO_ENGINE=subst cmake --build build --target bootstrap`) | **green**: 4b JS fixed point, 8c native fixed point, and 9b `eco` → `eco-2`. `eco-compiler-boot`, `eco-compiler-boot-2` and `eco-2` are byte-identical (md5 `33b3de44…`); `eco make` Hello World runs. The memory-pressure reaper interrupted the first attempt at step 118/120, after 8c; a resume finished the last two steps. |

**Expected effect of what shipped.** From § 12 row `n384_s16_sfl` minus the granule's solo effect:
wall about −3 s, CPU about −3 to −5 s, pause p99 about 28 → 18–19 ms, promoted +2.3 %. **Not
measured as shipped:** the next sweep baseline (now these defaults) will give the exact figure.

Updated along with the code:
- `AllocatorCommon.hpp` constants, with comments recording both reverts.
- HEAP_057 (OPEN note) and HEAP_070 (granule wording).
- `heap-profile.py` `BASELINE_HEAP` and `heap-config.json`, regenerated and round-trip checked
  (88/88).
- `docs/options.md`.
- `StringOpsTest.cpp` and the three Elm E2E tests.
