# GC parameter sensitivity sweep — 2026-09-22

Harness: `heap-profile.py sweep --variants-file plans/gc-param-sweep/sensitivity-2026-09-22.json`
Results: `/work/heap-profiles/ws-dev-01/2026-09-22T12-07-21Z__gc-sensitivity/`
Workload: Stage-7 self-compile, cold `eco-stuff`, run to completion. 42 cells, N=1, ~2 h 50 m.
21 parameters, each swept one-at-a-time below/on/above its compiled-in default.

## Method note: the counters classify, the wall only ranks

GC counters are exact per (binary x tree). **22 cells came back with `major_gcs` and
`minor_gcs` BIT-IDENTICAL to baseline** — for those the parameter provably did nothing to
the collector, so their wall spread IS the machine noise. That gives an empirical noise
floor with no extra runs: **sd 2.6 s, 2σ = 5.3 s** (excluding `hdfs_off`, which has
identical counts but changes the cost of each copy, so it is a real effect).
`baseline` 233.8 s vs `baseline_end` 228.3 s = **-5.5 s of drift** across the sitting,
consistent with that floor. Nothing inside ±5.3 s is readable at N=1.

## Sensitive parameters

| cell | Δwall | ΔGC | majors | minors | promoted MiB | nursery copies | old-gen peak MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| `baseline` | — | — | 10 | 1114 | 17,616 | 1.371 B | 9,125 |
| **`abuf_128K`** | **-61.7** | -12.2 | 20 | 3501 | 19,895 | 1.464 B | 8,439 |
| `age_1` | -17.7 | -11.8 | 9 | 1032 | 18,065 | **0.714 B** | 10,342 |
| `nmbc_512` | -17.6 | -7.9 | 9 | 2099 | 19,497 | 1.447 B | 9,782 |
| `mio_0.95` | -11.8 | -9.9 | **5** | 1114 | 17,616 | 1.371 B | **11,709** |
| `hdfs_off` | +8.1 | +3.8 | 10 | 1114 | 17,616 | 1.371 B | 9,085 |
| `mgf_0.50` | +8.6 | +9.7 | 14 | 1114 | 17,616 | 1.371 B | 7,430 |
| `mio_0.75` | +10.6 | +12.2 | 18 | 1114 | 17,616 | 1.371 B | 6,342 |
| `age_3` | +12.6 | +14.1 | 10 | 1180 | 16,950 | **1.998 B** | 8,926 |

- **`alloc_buffer_size` is the dominant knob and the result is NOT mainly a GC effect.**
  128K is -61.7 s (-26.4 %), of which **-49.5 s is MUTATOR time** and only -12.2 s is GC —
  and it gets there while doing MORE collector work (20 majors vs 10, 3501 minors vs 1114,
  +2,279 MiB promoted, +93 M nursery copies). 256K is only -4.8 s, so the response is not
  monotone in the obvious direction. 512K is the architectural ceiling (`OldGenSpace.cpp:256`,
  uint16 `cell_offset_8`), so this parameter can only go down.
  **Leading hypothesis: cache locality.** The box is a Xeon 6521P with **16 MiB of L3**;
  the baseline nursery grows to 512 MB (256 MiB semi-space), `abuf_128K` caps at 128 MB
  (64 MiB semi-space). Against expectation, too: 128K blocks mean MORE nursery slow-path
  entries (HEAP_034 pre-clamps `bump.end` per block), which should cost the mutator, not
  save it. **UNVERIFIED — needs a perf run on cache-miss counters, and the output was not
  hashed (see Owed).**
- **`promotion_age` is the clean monotone lever on survivor copying.** 1 / 2 / 3 gives
  nursery copies **0.714 B / 1.371 B / 1.998 B** — the mechanism is exactly as modelled, and
  time follows (-17.7 / 0 / +12.6 s). `age_1` trades +449 MiB promoted and +13 % old-gen peak
  for half the copying.
- **`major_gc_initiating_occupancy` is the clean lever on major count**: 0.75 / 0.85 / 0.95
  gives 18 / 10 / **5** majors and 34.97 / 23.06 / 14.22 s of major GC. **But memory pays
  for it**: old-gen peak 6,342 / 9,125 / **11,709** MB. `mgf` is the same trigger story
  from the garbage side (14 / 10 / 9 majors), and only bites when tightened.
- **`use_hybrid_dfs` earns its default**: counters bit-identical, +8.1 s when off. It
  changes the cost of each copy, not the number.
- **`nursery_max_block_count` 512 is a real -17.6 s** — halving the nursery ceiling to
  256 MB. Same direction as `abuf_128K`, consistent with the locality story.
- Weak/borderline: `ngct_0.99` -7.2 s (minors 1114 -> 1061, promoted -281 MiB — small but
  real direction), `lot_4K` -8.5 s (counters essentially identical, so most of this is noise),
  `nmbc_2048` +3.0 s despite **far** fewer minors (645) and -3,063 MiB promoted — more
  evidence that promotion volume is not what costs the time here.

## Provably inert on this workload (counters bit-identical to baseline, both directions)

`major_gc_target_utilization` · `initial_old_gen_size` · `decommit_on_oldgen_release` ·
`small_class_heap_budget_bytes` · `small_class_cell_max_bytes` · **`mark_work_ratio`** ·
`sweep_work_budget` · `initial_sweep_budget` · `sweep_bytes_per_alloc_byte` ·
`max_sweep_bytes_per_alloc`

Ten parameters, twenty cells, zero effect on any collector counter. The four sweep-pacing
ones were predicted inert (sweep is 4.6 % of major GC, and committed/cap peaks at 0.4456,
below `sweep_cap_ratio_low` 0.50, so the pressure ladder never leaves its lowest step).
`mark_work_ratio` was predicted SENSITIVE and is not: it paces *incremental* marking, it does
not change how much marking there is. `major_gc_target_utilization` was also predicted
sensitive and is not — the post-major growth rule rarely binds when old-gen peaks at 44.6 %
of cap. `nursery_growth_threshold` and `string_flatten_limit` move counters trivially and
are within noise.

## Owed before acting on any of this

1. **Per-cell output verification.** Each cell overwrites `bin/eco-compiler-boot.mlir`, so
   only the last cell's output survives — it IS byte-identical to `ecoghash.mlir`, but that
   verifies `baseline_end` alone. A config that produced WRONG output would currently read
   as a win, and `abuf_128K` is exactly the cell where that matters. **Record an output hash
   per variant in the harness before the next sitting.**
2. **Repeat `abuf_128K`** — a -26 % single-run result larger than the entire 43-experiment
   LSS loop deserves an interleaved A/B, not N=1.
3. **Decouple `alloc_buffer_size`.** It changes the nursery size AND the old-gen page size at
   once. Pair it with `nursery_max_block_count` to hold max nursery constant and see which
   half carries the win.
4. **Combination run.** `age_1`, `mio_0.95` and `nmbc_512`/`abuf_128K` act on different
   mechanisms (copying, major frequency, footprint), so they may compose — with a
   leave-one-out set to find who actually carries the gain. Watch old-gen peak: `mio_0.95`
   alone is +28 %, and this box has 15 GB of RAM.

---

# RETRACTION (same day): `abuf_128K` was a CRASH, not a win

The combination run (`plans/gc-param-sweep/combinations-2026-09-22.json`) put
`alloc_buffer_size=128K` into seven cells. **All seven took SIGSEGV** at 109-167 s and
produced no output. Re-reading this sweep's own log for `abuf_128K` then showed
`[gc-stats] SIGSEGV — printing GC statistics` in its stderr — **it crashed too, and the
harness recorded rc=0.**

So the -61.7 s (-26 %) headline was the compiler dying partway through. The "-49.5 s of
MUTATOR time" was work never done, and 172.1 s is a time-to-crash, not a compile time.
The cache-locality hypothesis explained a measurement that did not exist.

**`alloc_buffer_size` = 128K is UNSAFE on this tree** — 8 crashes from 8 attempts. This is a
runtime defect, not a tuning result: a config inside `HeapConfig::validate()`'s bounds must
not segfault. 256K completed cleanly (`abuf_256K`, -4.8 s, inside noise), so the fault is
somewhere between 128K and 256K blocks. Worth a bug hunt on its own — the GC profile before
the crash shows the old gen ballooning to 22,432 blocks with 1.5 GB live against 4.8 GB
garbage, and majors climbing 9 ms -> 3,446 ms.

**Scan of all 42 cells for `SIGSEGV|SIGABRT`: only `abuf_128K`.** Every other cell in this
sweep terminated normally, so the rest of the analysis above stands unchanged — including
the ten provably-inert parameters and the `promotion_age` / `mio` / `nmbc` findings.

## The methodological lesson, which is the durable part

**`rc == 0` is not proof that a run completed.** The runtime's fatal-signal handler prints GC
statistics and the process still exited 0, so every downstream check — wall time, GC counters,
the parsed stats banner — looked perfectly healthy on a run that had crashed. The stats were
real; they just covered a truncated run.

What actually caught it was the **output artifact**: no `eco-compiler-boot.mlir`. Two harness
changes followed:
1. `out_bytes` / `out_md5` per variant, compared against the known-good output.
2. A `signal` column, from the runtime's own `[gc-stats] SIG...` marker in stderr, because rc
   cannot be trusted.

A benchmark cell must prove it did the work. The fastest cell is exactly where that proof
matters most, because "it didn't do the work" and "it was fast" are the same observation.
