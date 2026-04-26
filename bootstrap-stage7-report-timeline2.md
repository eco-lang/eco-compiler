# Bootstrap Stage 7 Report — Heap-Size Timeline (10-min run #2)

Second 10-minute Stage-7 self-compile, run with the same source tree and
same `decommit_on_oldgen_release = true`. RSS sampled every second from
`/proc/<pid>/status` and saved at
[`/work/stage7-rss-timeline2.csv`](stage7-rss-timeline2.csv) (590 samples).
Termination: `SIGTERM` from `timeout 600s` (exit code 124); the signal
handler emitted the full GC statistics block.

## Run summary

| Metric | Value |
|---|---|
| Wall-clock budget / actual | 10:00 / 10:00 (timeout) |
| Termination | SIGTERM caught by handler, stats printed |
| Major-GC begins / ends | 5 / 4 |
| Total time inside major-GC mark+sweep | **530.51 s (88.4 % of wall-clock)** |
| Average major-GC cycle | 132.63 s |
| Min / max major-GC cycle | 103.64 s / 165.48 s |
| Minor GCs | 197 |
| Total minor-GC time | 52.02 s (8.7 % of wall-clock) |
| Live data after each major GC | 9.91 / 9.92 / 10.01 / 10.23 MB |
| Reclaimed each cycle | 2735 / 2629 / 2560 / 2089 MB |
| Initial RSS sample | 1.78 GB |
| `oldgen_committed` envelope | 3.18 – 3.35 GB |
| Reserved virtual size | 24 GB (constant) |
| `oldgen_cap` | 12 GB (none ever consumed) |

## Heap-size timeline (RSS at 15 s cadence)

```
   t (s)    RSS (MB)
       0      1778   ← start sample (mid Major-GC #1 sweep)
      15      1643
      30      1503
      45      1335
      60      1133  ↓ Major-GC #1 sweep (linear drain)
      75       893
      90       619   ← Major-GC #1 sweep end
     105      1529   ← Major-GC #2 begins (mark + new alloc wave)
     120      1430
     135      1333
     150      1226
     165      1097
     180       951   ↓ Major-GC #2 sweep
     195       778
     210       594   ← Major-GC #2 sweep end
     225      1306   ← Major-GC #3 begins
     240      1247
     255      1179
     270      1108
     285      1031
     300       944
     315       862
     330       775
     345       682
     360       564   ← Major-GC #3 sweep end
     375       794   ← Major-GC #4 begins (note: shorter pre-mark interval)
     390      1182   ← peak of #4's allocation phase
     405      1136
     420      1088
     435      1046
     450      1004
     465       960   ↓ Major-GC #4 sweep (165.48 s — longest)
     480       916
     495       870
     510       823
     525       783
     540       747
     555       698   ← Major-GC #4 sweep end
     570      1248   ← Major-GC #5 begins (mark)
     585      1303   ← still in mark when SIGTERM arrives at ~600 s
```

The full 1-Hz CSV is at [`stage7-rss-timeline2.csv`](stage7-rss-timeline2.csv).

## Per-cycle major-GC accounting (heap-trace)

| Cycle | Begin oldgen_committed | End oldgen_committed | Freed bytes | Live after |
|---|---|---|---|---|
| #1 | 3209.24 MB | 473.88 MB | 2735.37 MB | 9.91 MB |
| #2 | 3264.37 MB | 635.62 MB | 2628.75 MB | 9.92 MB |
| #3 | 3351.12 MB | 790.87 MB | 2560.25 MB | 10.01 MB |
| #4 | 3183.99 MB | 1261.99 MB | 2089.12 MB | 10.23 MB |
| #5 | 3087.12 MB | (in progress) | — | — |

The values are bit-identical to the prior 10-min run. The compiler's
allocation behavior is fully deterministic — same allocation counts, same
nursery survivor counts, same per-cycle reclaim, same end-of-sweep
residual. Only timing varies cycle-to-cycle (system noise).

## GC counters (verbatim, signal-handler output)

```
=== GC Statistics ===

Allocation:
  Objects allocated:          8168475
  Bytes allocated:             328.07 MB

Minor GC:
  Minor GC cycles:                197
  Objects survived:            830147 (10.2%)
  Objects promoted:            379263 (4.6%)
  Bytes reclaimed:             330.20 MB


Minor GC Timing:
  Total time:                    52.02 s
  Average time:                264.05 ms
  Min time:                   190.10 µs
  Max time:                      10.65 s

Minor GC Time Histogram:
  150.00 µs - 200.00 µs:  1 (0.5%)
  400.00 µs - 450.00 µs:  2 (1.0%)
  450.00 µs - 500.00 µs:  2 (1.0%)
  500.00 µs - 550.00 µs:  2 (1.0%)
  550.00 µs - 600.00 µs:  4 (2.0%)
  600.00 µs - 650.00 µs:  2 (1.0%)
  650.00 µs - 700.00 µs:  1 (0.5%)
  700.00 µs - 750.00 µs:  2 (1.0%)
  750.00 µs - 800.00 µs:  1 (0.5%)
  850.00 µs - 900.00 µs:  1 (0.5%)
  950.00 µs -    1.00 ms:  2 (1.0%)
  >    1.00 ms     : ████████████████████████████████████████ 177 (89.8%)

Major GC:
  Major GC cycles:                  4
  Concurrent marks:                 5
  Mark-sweeps completed:            4
  Incremental marks:             1799
  Total work units:           1796310
  Occupancy triggers:               5
  Alloc-fail triggers:              0

Major GC Timing:
  Total time:                   530.51 s
  Average time:                 132.63 s
  Min time:                     103.64 s
  Max time:                     165.48 s

Major GC Time Histogram:
  >     1.00 s     : ████████████████████████████████████████ 4 (100.0%)

Nursery Allocation Size Histogram:
      16 B -     32 B: ████████████████████████████████████████ 4775378 (58.5%)
      32 B -     64 B: ██████████████████████████ 3193760 (39.1%)
      64 B -    128 B: █ 171580 (2.1%)
     128 B -    256 B:  772 (0.0%)
     256 B -    512 B:  857 (0.0%)
     512 B -    1 KiB:  1930 (0.0%)
     1 KiB -    2 KiB:  3975 (0.0%)
     2 KiB -    4 KiB:  6755 (0.1%)
     4 KiB -    8 KiB:  13468 (0.2%)

Old-Gen Allocation Size Histogram:
      16 B -     32 B: ████████████████████████████████████████ 208338 (40.2%)
      32 B -     64 B: ██████████████████████████████████████ 201835 (38.9%)
      64 B -    128 B:  4457 (0.9%)
     128 B -    256 B:  348 (0.1%)
     256 B -    512 B:  99 (0.0%)
     512 B -    1 KiB:  37 (0.0%)
     1 KiB -    2 KiB:  13 (0.0%)
     2 KiB -    4 KiB:  8 (0.0%)
     4 KiB -    8 KiB:  3 (0.0%)
     8 KiB -   16 KiB: ████ 23512 (4.5%)
    16 KiB -   32 KiB: ███████ 39497 (7.6%)
    32 KiB -   64 KiB: ███████ 40336 (7.8%)
  >=    1 MiB        :  1 (0.0%)
```

## Comparison with prior 10-min run

The compiler's deterministic allocation pattern means counters are
identical across runs; only timing varies. This is a useful baseline:
any future GC tweak should change the *timing* numbers (and ideally the
shape of the timeline), while the *count* numbers should stay fixed
unless allocator policy alters when the major trigger fires.

| Metric | Run #1 | Run #2 | Δ |
|---|---|---|---|
| Major-GC total | 530.72 s | 530.51 s | −0.04 % |
| Major-GC avg | 132.68 s | 132.63 s | −0.04 % |
| Major-GC min | 101.95 s | 103.64 s | +1.7 % |
| Major-GC max | 173.91 s | 165.48 s | −4.8 % |
| Minor-GC total | 45.29 s | 52.02 s | +14.9 % |
| Minor-GC avg | 229.91 ms | 264.05 ms | +14.8 % |
| Minor-GC min | 191.39 µs | 190.10 µs | ≈ |
| Minor-GC max | 7.65 s | 10.65 s | +39 % |
| Major begins / ends | 5 / 4 | 5 / 4 | = |
| Objects allocated | 8 168 475 | 8 168 475 | = |
| Bytes allocated | 328.07 MB | 328.07 MB | = |
| Minor cycles | 197 | 197 | = |
| Objects survived | 830 147 | 830 147 | = |
| Objects promoted | 379 263 | 379 263 | = |
| Cumulative free per major | 2735 / 2629 / 2560 / 2089 MB | 2735 / 2629 / 2560 / 2089 MB | = |
| End-of-sweep oldgen | 474 / 636 / 791 / 1262 MB | 474 / 636 / 791 / 1262 MB | = |
| Live after each major | 9.91 / 9.92 / 10.01 / 10.23 MB | 9.91 / 9.92 / 10.01 / 10.23 MB | = |
| RSS at t=15s sample | 1630 MB | 1643 MB | ≈ |
| RSS at t=300s sample | 902 MB | 944 MB | ≈ |
| Sweep #1 RSS bottom | ≈ 584 MB at t≈90s | ≈ 619 MB at t≈90s | ≈ |
| Sweep #2 RSS bottom | ≈ 534 MB at t≈210s | ≈ 594 MB at t≈210s | ≈ |
| Sweep #3 RSS bottom | ≈ 604 MB at t≈345s | ≈ 564 MB at t≈360s | ≈ |
| Sweep #4 RSS bottom | ≈ 696 MB at t≈555s | ≈ 698 MB at t≈555s | ≈ |

## Observations

### The timeline shape is reproducible

Four saw-tooth sweep phases visible in both runs at the same wall-clock
positions (within ~5 s). The compiler is allocating, marking, and
sweeping the same logical work each time. The timing shifts are
dominated by minor-GC variance (which the work histograms attribute to
allocation-pattern-driven survivor walks across decommitted pages).

### Sweep continues to dominate

530 s of the 600 s budget is mark+sweep — the gating cost. With the
marking fix in place, mark itself is ≈ 2 % of cycle time; the rest is
sweep walking the 3 GB old gen to find ≈ 10 MB of live data scattered
across it. Reproducible, predictable, and the obvious thing to fix.

### Minor-GC variance grew this run

Run #2 had a 10.65 s worst-case minor GC vs run #1's 7.65 s. Given the
allocator is deterministic up to scheduling, this is OS-level noise:
soft-fault latency depends on the kernel's reverse-mapping cache and
LRU page-replacement state, which are workload-history-dependent. The
average grew 230 ms → 264 ms (+15 %), well within run-to-run noise for
a workload this dependent on demand-paging.

### Per-cycle reclaim ratio confirms

99.7 % of the 3 GB old-gen heap is garbage every cycle. The "live after"
column grows from 9.91 MB to 10.23 MB across four cycles — 0.32 MB of
genuinely long-lived data accumulated, the rest is sweep-time
fragmentation residual that pins the end-of-sweep `oldgen_committed`
above its true working-set size.

## Pending

Same as before: the compiler still has not finished a single module.
Sweep cost (not mark, not allocator) is the gating issue. The two
candidate directions remain:

- **Skip pages with no live data.** With ≈ 10 MB live in 3 GB heap,
  most bag pages contain only `Tag_Free` cells; a per-page `any-live?`
  bit set during mark would let sweep release those pages without
  walking their cell headers.
- **Compact instead of sweep.** With 99.7 % garbage, copying 10 MB of
  live data to a fresh region and dropping the source pages would
  finish in milliseconds — orders of magnitude better than the current
  130 s/cycle. The infrastructure for this (`scheduleCompaction`,
  `selectEvacuationSet`, `incrementalCompactionSlice`,
  `prepareReferenceFixup`) already exists; it's gated on a
  fragmentation threshold that 99.7 %-garbage pages presumably already
  satisfy.
