---
title: GC Parameter Sweep Experiment
status: ready
date: 2026-05-02
---

# GC Parameter Sweep Experiment

## Goal

Find a parameter set that beats the current baseline by:

1. Sweeping each tunable **one at a time** with 60 s runs.
2. Picking the best value per parameter (the "promising" set).
3. Combining promising values and running a second round of 60 s runs.

Driver: `heap-profile.py sweep --variants-file <file> --wall-seconds 60`.
Workload: Stage 7 self-compile (`eco-compiler make ... eco-compiler-boot.mlir`)
— the workload baked into `run_variant`. Each cell is run once (N=1), serially.

## Baseline

```json
{
  "max_heap_size":                 "24G",
  "initial_old_gen_size":          "16M",
  "alloc_buffer_size":             "128K",
  "nursery_block_count":           64,
  "nursery_max_block_count":       2048,
  "promotion_age":                 2,
  "nursery_gc_threshold":          0.9,
  "nursery_growth_threshold":      0.025,
  "major_gc_initiating_occupancy": 0.75,
  "major_gc_target_utilization":   0.70,
  "major_gc_garbage_fraction":     0.40,
  "use_hybrid_dfs":                true,
  "large_object_threshold":        "16K",
  "decommit_on_oldgen_release":    true
}
```

The baseline above matches the `BASELINE_HEAP` constant in
`heap-profile.py` exactly. `heap-profile.py:cmd_sweep` builds each cell's
config as `BASELINE_HEAP | overrides`, so each variant in `phase1.json`
overrides only the single parameter being swept, and the `baseline` cell
uses an empty `overrides` dict.

## Metrics

Primary metric: **`mutator_pct`** (higher is better) — fraction of wall time
spent outside GC and helper work. `heap-profile.py` already computes this.

Secondary tie-breaker: **total GC time** = `major_s + minor_s + helper_s`
(lower is better). Used when two configs are within ~1 pp on `mutator_pct`.

Reported but not optimized for: `peak_commit_MB`, `final_live_MB`, `major_gcs`,
`minor_gcs`, `alloc_MBps`. Useful for sanity checks (a config that "wins" by
never triggering a major GC inside 180 s is a 180 s artefact, not a win).

## Phase 1 — One-at-a-time sweep

Prerequisite: Step 0 above (update `BASELINE_HEAP`). After that, the
variant matrix is passed via `--variants-file phase1.json`. Each variant
overrides only the single parameter under test; all other fields inherit
from `BASELINE_HEAP`.

| # | Parameter | Sweep values (baseline **bold**) | Non-baseline runs |
|---|---|---|---|
| 1 | `alloc_buffer_size` | 64K, **128K**, 256K, 512K, 1M | 4 |
| 2 | `promotion_age` | 1, **2**, 3 | 2 |
| 3 | `nursery_growth_threshold` | **0.025**, 0.05, 0.10, 0.15, 0.20 | 4 |
| 4 | `major_gc_initiating_occupancy` | 0.55, 0.65, **0.75**, 0.85, 0.95 | 4 |
| 5 | `major_gc_target_utilization` | 0.50, 0.60, **0.70**, 0.80, 0.90 | 4 |
| 6 | `large_object_threshold` | 128, 256, 512, 1K, 2K, 4K, 8K, **16K**, 32K, 64K | 9 |
| 7 | `major_gc_garbage_fraction` | 0.20, 0.30, **0.40**, 0.55, 0.70 | 4 |
| 8 | `nursery_max_block_count` | 1024, **2048**, 4096 | 2 |

**Run count:** 1 baseline + 33 sweep cells = **34 runs × 60 s ≈ 34 min**
of pure runtime. Serial; no parallelism.

### Variant naming convention

`<param_short>_<value>`, e.g. `abuf_64K`, `nbc_128`, `age_3`, `ngt_0.05`,
`mio_0.95`, `mtu_0.50`, `lot_4K`, `lot_128`, `lot_512`, `mgf_0.70`,
`nmbc_4096`. Plus one explicit `baseline`.
Names go straight into the JSON variants file and become folder names under
`variants/<name>/`.

### Phase 1 invocation

```
./heap-profile.py sweep \
    --variants-file plans/gc-param-sweep/phase1.json \
    --wall-seconds 60 \
    --label gc-sweep-phase1
```

Resume on interruption with the same command + `--resume-dir <existing>`;
already-recorded variants are skipped via `runs.tsv`.

## Phase 2 — Compare

Inputs: the `runs.tsv` produced by Phase 1.

For each parameter:

1. Sort its non-baseline rows + baseline by `mutator_pct` desc (4 cells per
   parameter, except 9 for `large_object_threshold` and 2 for `promotion_age`).
2. The best non-baseline value is "promising" if
   `mutator_pct(best) - mutator_pct(baseline) >= 1.0` percentage points
   **and** the run did not crash / exit before 180 s.
3. Note shape (monotone vs. U-shape) and whether the optimum sits at the edge
   of the swept range.
4. Crashes: dropped from selection but listed in the report with their failure
   mode; they are not scored as 0.

Output: `plans/gc-param-sweep/phase1-results.md` with the per-parameter table
and the chosen `P*` set.

## Phase 3 — Combination runs

Goal: catch interactions that one-at-a-time sweeps miss.

Let `k = |P*|`. Build `phase3.json` with:

1. **`combo_all`** — every promising parameter set to its Phase 1 best value
   simultaneously. (1 run.)
2. **`combo_loo_<param>`** — `k` leave-one-out variants: same as `combo_all`
   but with one promising parameter reverted to baseline. Tells us which
   parameters actually carry the gain.
3. **`combo_pair_<a>_<b>`** — only when Phase 2 surfaces two clearly dominant
   parameters; bounds the gain attributable to that pair alone.

Total Phase 3 runs ≈ `1 + k (+1)`; with `k ≤ 4` realistic, ≈ 4–6 runs ≈ 12–18 min.

Same invocation pattern as Phase 1 with `--label gc-sweep-phase3` and
`--variants-file plans/gc-param-sweep/phase3.json`.

## Phase 4 — Report

Single markdown file `plans/gc-param-sweep/results.md`:

- Phase 1 table — best value and Δ `mutator_pct` vs baseline per parameter,
  with secondary GC-time column.
- Phase 3 table — each combination's Δ vs baseline and Δ vs `combo_all`.
- Proposed new baseline if `combo_all` (or a leave-one-out variant) beats the
  current baseline by ≥ 1 pp on `mutator_pct`.
- List of parameters whose sweep should be extended (best value at the edge
  of the swept range) — flagged but not auto-extended in this run.
- List of crashed cells with the variant name, override, and the line from
  `stderr.log` that identifies the failure.

## Risks / caveats (carried forward, not blocking)

- **Single-shot runs (N=1)**: no per-cell variance estimate. Two configs
  within ~1 pp on `mutator_pct` may not be distinguishable; the 1 pp threshold
  is a deliberately wide band to avoid chasing noise.
- **3 min may be too short** for slow-GC configurations (high
  `major_gc_initiating_occupancy`, large nursery) to trigger several major GCs.
  Such configs may show inflated `mutator_pct` simply by deferring GC past the
  180 s window. The `major_gcs` count column in `runs.tsv` is the cross-check;
  flag any winning cell with < 2 major GCs in the Phase 4 report.
- **Edge-of-range optima** are not auto-extended; flagged for a follow-up sweep.
- **`promotion_age`** has only 3 valid values, so even if it looks promising it
  contributes little to combination space.
