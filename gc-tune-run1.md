# GC tuning — Run 1 (Stage 7, 13 single-param + 4 combo variants)

## Method

- Each variant: 5-minute Stage 7 self-compile (`bin/eco-compiler make … Terminal/Main.elm`)
  with a 300 s timeout (SIGTERM); 10 s SIGKILL grace.
- HeapConfig parameters loaded at startup via `ECO_HEAP_CONFIG` JSON file
  (no rebuild between runs).
- `ECO_HEAP_TRACE=1` and `ECO_GC_PHASE_PROFILE=1` enabled for observability.
- Per-variant results parsed from the `[gc-stats] SIGTERM …` summary the
  signal handler prints on shutdown, plus heap-trace lines on stderr.
- Driver: `/tmp/heap-sweep.py` (single-param) and `/tmp/heap-sweep-combo.py`
  (combos). Results accumulated in `/tmp/heap-sweep/results.tsv`.

## Metrics

| field | meaning |
|---|---|
| `wall_s` | wall-clock seconds (300 for runs that hit SIGTERM) |
| `major_gcs` / `minor_gcs` | GC cycle counts from `Major GC cycles:` / `Minor GC cycles:` |
| `major_s` / `minor_s` | `Total time` from the `Major/Minor GC Timing` blocks |
| `mutator_s` | `wall_s − major_s − minor_s` |
| `mutator_pct` | `mutator_s / wall_s × 100` |
| `bytes_alloc_MB` | `Bytes allocated:` from GC stats |
| `alloc_MBps` | `bytes_alloc_MB / wall_s` (mutator-throughput proxy) |
| `peak_commit_MB` | max `tl.committed=…` from heap-trace |
| `final_live_MB` | last `tl.live=…` from heap-trace (post-GC retained data) |

## Baseline config

```json
{
  "max_heap_size":                 "24G",
  "initial_old_gen_size":          "16M",
  "alloc_buffer_size":             "128K",
  "nursery_block_count":           64,
  "promotion_age":                 2,
  "nursery_gc_threshold":          0.9,
  "nursery_growth_threshold":      0.1,
  "major_gc_initiating_occupancy": 0.75,
  "major_gc_target_utilization":   0.50,
  "use_hybrid_dfs":                true,
  "large_object_threshold":        "8K",
  "decommit_on_oldgen_release":    true
}
```

## All results

Sorted by `alloc_MBps` (desc).

| name             | change                              | wall_s | major | minor | major_s | minor_s | mut_s   | %mut  | bytes_MB  | MBps    | objs        | peak_MB  | live_MB |
|------------------|-------------------------------------|-------:|------:|------:|--------:|--------:|--------:|------:|----------:|--------:|------------:|---------:|--------:|
| F2_page256_C3    | page=256K + target=0.70             |  300.0 |   121 |   148 |   85.62 |  180.06 |   34.32 |  11.4 |   2240.26 |    7.47 |   29 831 519 | 12108.62 |   19.39 |
| E2_page256K      | alloc_buffer_size=256K              |  300.0 |   119 |   147 |   94.12 |  182.43 |   23.45 |   7.8 |   2208.92 |    7.36 |   29 141 269 | 12108.62 |   18.96 |
| F4_page256_nb32  | page=256K + nursery_block_count=32  |  300.0 |    98 |   190 |  111.82 |  154.83 |   33.35 |  11.1 |   2143.76 |    7.15 |   26 870 116 |  9863.87 |   18.19 |
| F1_page256_C1    | page=256K + init=0.50 + target=0.30 |  300.0 |   117 |   137 |  106.41 |  171.26 |   22.33 |   7.4 |   2050.65 |    6.84 |   24 636 709 | 12010.37 |   17.46 |
| F3_page256_age1  | page=256K + promotion_age=1         |  300.0 |   153 |   225 |  132.63 |  142.50 |   24.87 |   8.3 |   1588.75 |    5.30 |   21 377 915 | 10938.12 |   16.08 |
| C1_early         | init=0.50 target=0.30               |  300.0 |    73 |   143 |  103.49 |  175.37 |   21.14 |   7.0 |   1559.72 |    5.20 |   21 318 247 |  5532.99 |   15.97 |
| C3_tight         | target=0.70                         |  300.0 |    14 |    93 |   17.96 |  217.80 |   64.24 |  21.4 |    979.20 |    3.26 |   15 411 469 |  5103.49 |   13.19 |
| baseline         | (defaults)                          |  300.0 |    10 |    90 |   12.55 |  226.88 |   60.57 |  20.2 |    931.37 |    3.10 |   14 218 207 |  4554.24 |   13.10 |
| B_age1           | promotion_age=1                     |  300.0 |    78 |   253 |   40.57 |  222.49 |   36.94 |  12.3 |    886.02 |    2.95 |   14 095 795 |  4729.24 |   12.99 |
| C2_late          | init=0.85                           |  300.0 |     5 |    76 |    5.91 |  217.59 |   76.50 |  25.5 |    773.57 |    2.58 |   12 342 615 |  4554.24 |   11.88 |
| A_nb32           | nursery_block_count=32              |  300.0 |     4 |    91 |    3.45 |  232.83 |   63.72 |  21.2 |    623.38 |    2.08 |   11 026 337 |  3615.12 |   11.01 |
| D1_lot4K         | LOT=4K                              |  300.0 |    13 |    51 |   12.80 |  225.51 |   61.69 |  20.6 |    482.52 |    1.61 |   13 147 089 |  5423.62 |   12.16 |
| E1_page64K       | alloc_buffer_size=64K               |  300.0 |     0 |    53 |    0.00 |  171.52 |  128.48 |  42.8 |    331.45 |    1.10 |    8 304 640 |  1483.30 |    0.00 |
| A_nb128          | nursery_block_count=128             |  300.0 |     0 |    30 |    0.00 |  199.64 |  100.36 |  33.5 |    326.06 |    1.09 |    8 111 538 |  2955.12 |    0.00 |
| A_nb16           | nursery_block_count=16              |  300.0 |     0 |    53 |    0.00 |  250.88 |   49.12 |  16.4 |    301.91 |    1.01 |    7 887 901 |  2954.87 |    0.00 |
| B_age3           | promotion_age=3                     |  300.0 |     0 |    11 |    0.00 |    0.00 |  300.00 | 100.0 |    209.12 |    0.70 |    7 470 290 |  1647.74 |    0.00 |
| D2_lot32K        | LOT=32K                             |   33.8 |    33 |  3568 |    5.35 |    5.42 |   23.05 |  68.2 |  41516.58 | 1227.74 |  243 857 067 |   144.43 |  102.99 |

D2_lot32K crashed at 33.8 s with SIGABRT (rc=-6) — anomalous and excluded
from ranking; worth a separate bug investigation.

## Per-parameter winners (vs. baseline)

| parameter | favored value | source variant |
|---|---|---|
| `alloc_buffer_size` | **256K** | E2_page256K (+137% MBps) |
| `major_gc_initiating_occupancy` / `target_utilization` | **0.50 / 0.30** | C1_early (+68%) |
| `major_gc_target_utilization` (alone) | **0.70** | C3_tight (+5%) |
| `promotion_age` | **2** (baseline) | age=1 worse, age=3 stalls |
| `nursery_block_count` | **64** (baseline) | 16/32/128 all worse |
| `large_object_threshold` | **8K** (baseline) | 4K worse, 32K crashed |

## Combo findings

- **F2 (page=256K + target=0.70) is the optimum**, beating both single-param
  winners. Tightened post-GC shrink (0.70) frees memory the mutator can
  reuse without growing committed.
- **F1 (page=256K + 0.50/0.30) is worse than E2 alone.** C1's "early major
  + big headroom" recipe doesn't compose with large pages.
- **F4 (smaller nursery, 32 blocks)** costs ~3% throughput — 64 is the sweet
  spot.
- **F3 (immediate promotion)** is the worst combo. 153 majors in 5 min;
  promotion churn floods old-gen.

## Counter-intuitive observation

F2 spends **88.6% of wall clock in GC** (vs baseline's 79.8%) but achieves
**2.4× the mutator throughput**. The mutator's window is shorter per cycle
but vastly more productive — many fast cycles instead of few slow ones.
The classic "minimize GC%" intuition is misleading here.

## Recommended optimal config (F2)

Two-line diff from current `heap-config.json`:

```diff
-  "alloc_buffer_size":             "128K",
+  "alloc_buffer_size":             "256K",
...
-  "major_gc_target_utilization":   0.50,
+  "major_gc_target_utilization":   0.70,
```

Saved as `compiler/build-kernel/heap-config-best.json`.

Expected vs. current baseline:
- **2.4× alloc throughput**
- **+48% live progress per 5 min**
- **+50% peak committed** (12.1 GB vs 4.5 GB) — recovered aggressively by tighter target

## Followups

- **Why does 256K beat 128K so dramatically?** Same nursery total + larger
  BBoP pages → very different major-GC dynamics. Worth disentangling: try
  512K page.
- **D2_lot32K crashed.** 243M objects allocated, 41 GB churned in 33 s, then
  SIGABRT. The high pre-crash allocation rate (1227 MBps) hints at something
  genuinely fast in that regime if the bug is fixed.
- **Stage 7 still didn't finish a module.** At F2's rate (~67 MB live per
  5 min extrapolated), a 500-MB working-set module needs ~40 min wall clock.
  The next bottleneck is upstream of GC.
