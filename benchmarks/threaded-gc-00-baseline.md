# Threaded GC 00 — baseline

**What this is:** the measurements that `plans/threaded-gc-00-measure-and-fix.md` §5 asked for.
They are the reference that every later phase of `plans/threaded-gc-master-plan.md` is judged
against. The design context is in `design_docs/parallel-gc.md`.

## 0. Reference

| | |
|---|---|
| Date | 2026-09-24 |
| Machine | `ws-dev-01`: Xeon 6521P, 24 cores, no SMT, one NUMA node, 16 MiB shared L3, 15 GB RAM |
| MLIR | `build/compiler/build-kernel/bin/ecoghash.mlir`, the same reference MLIR as the whole GC loop series |
| Candidate | `bin/eco-optT00` = `ecoghash.mlir` lowered against the instrumented runtime (snapshot `try-T00`, patch `snapshots/lss-loop/step-T00.patch`) |
| Same-session control | `bin/eco-optW13c` re-run as `eco-optW13c-ctl` |
| Workload | self-compile of `compiler/src/Terminal/Main.elm`, solver+LSS, cold `eco-stuff`, commands of `benchmarks/gc-opt-loop.md` §2 |

**Instrumented-build provenance.** The timed runs below used the runtime *before* one late change.
The four external-root-scanner registrations in license-pinned kernel files (`Scheduler.cpp`,
`MVar.cpp`, `Runtime.cpp`, `HttpExports.cpp`) were restored byte-for-byte to satisfy the LSS_022
manifest guard. Those scanners are now labelled from their registration address instead of an
explicit name (plan §6a). The change touches only label strings, so it moves no timing and no
counter. The final binary was re-lowered and re-checked (§7).

## 1. Counters and output: bit-identical

| Run | Wall (s) | Minor GCs | Major GCs | Promoted MiB | Max RSS (kB) | GC (s) | `out.mlir` |
|---|---|---|---|---|---|---|---|
| T00 r1 | 185.34 | 1924 | 6 | 19861 | 9,725,544 | 69.83 | identical |
| T00 r2 | 185.18 | 1924 | 6 | 19861 | 9,726,288 | 69.80 | identical |
| T00 r3 | 186.76 | 1924 | 6 | 19861 | 9,725,636 | 70.08 | identical |
| T00, timers off, r1 | 184.71 | 1924 | 6 | 19861 | 9,726,136 | 69.29 | identical |
| T00, timers off, r2 | 183.84 | 1924 | 6 | 19861 | 9,726,068 | 69.06 | identical |
| T00, timers off, r3 | 183.94 | 1924 | 6 | 19861 | 9,726,284 | 68.82 | identical |
| T00 + event log | 181.51 | 1924 | 6 | 19861 | 9,724,516 | 68.48 | identical |
| W13c control | 184.94 | 1924 | 6 | 19861 | 9,723,332 | 68.38 | identical |

- **Every counter line of the banner is identical across all eight runs**: allocated
  254,094,395, promoted 675,767,781, copied-in-nursery 744,329,977, per-tag retention, and the
  major event log's promoted and mark-unit columns.
- The object-level counts differ from the W13c figures recorded in an **earlier session**
  (254,094,367 / 675,767,765). The same W13c binary re-run here reproduces this session's
  numbers exactly. The launch session and argument shape are program inputs: the compiler reads
  its arguments and part of its environment into Elm values (plan §6a.1). **Always judge
  counters against a same-session control.**

## 2. Instrument overhead (gate G8)

| | median wall | median GC | median minor | median true mutator |
|---|---|---|---|---|
| timers on | 185.34 s | 69.83 s | 61.04 s | 115.15 s |
| timers off (`ECO_GC_PHASE_TIMERS=0`) | 183.94 s | 69.06 s | 60.32 s | 114.75 s |
| Δ | +1.40 s (inside the 5.3 s band) | **+0.77 s (+1.1 % of GC)** | +0.72 s | +0.40 s |

The pause bracket (two clock reads per GC) is on in both arms. The +0.77 s is the cost of the
phase timers and the 1-in-16 / 1-in-256 sampling. That is within the GC-time noise of identical
work (about ±1.7 s at 2σ), and the plan's criterion (within 2σ, or ≤ 1 %) is met. **Gate
passed.** Run with `ECO_GC_PHASE_TIMERS=0` for the cleanest timing, and leave the timers on when
the anatomy is the question.

## 3. Pause distribution

A pause here is one contiguous mutator stop. A minor that triggers a major is one pause.

| | r1 | r2 | r3 |
|---|---|---|---|
| pauses (minor-only / minor+major) | 1918 / 6 | 1918 / 6 | 1918 / 6 |
| total pause time | 69.90 s | 69.87 s | 70.16 s |
| p50 | 5.86 ms | 5.76 ms | 5.94 ms |
| p90 | 138.5 ms | 138.2 ms | 139.0 ms |
| p99 | 158.6 ms | 158.7 ms | 159.0 ms |
| p99.9 | 2400.7 ms | 2390.2 ms | 2420.3 ms |
| **max** | **2673.0 ms** | **2661.3 ms** | **2659.7 ms** |
| minor-only max | 935.3 ms | 934.4 ms | 934.3 ms |
| pauses containing a major: p50 / max | 1321.6 / 2673.0 ms | 1318.4 / 2661.3 ms | 1343.6 / 2659.7 ms |

Pause log2 histogram (r1):

```
[0.128, 0.256) ms  508   <- a population of tiny minors
[0.256, 0.512) ms   86
[0.512, 1.024) ms   23
[1.024, 2.048) ms   61
[2.048, 4.096) ms  121
[4.096, 8.192) ms  269
[8.192, 16.38) ms  164
[16.38, 32.77) ms  188
[32.77, 65.54) ms  150
[65.54, 131.1) ms  137
[131.1, 262.1) ms  208   <- the steady-state 'full' minor: ~130-160 ms
[262.1, 524.3) ms    1
[524.3, 1049)  ms    4   <- post-major sweep bursts (§4.3)
[1049, 2097)   ms    1   <- majors
[2097, 4194)   ms    3   <- majors
```

**MMU** (r1, r2 and r3 agree to about 0.1 pt): 0 % for every window up to **2 s**, 11.4 % at
5 s, and 29.1 % at 10 s. The 2.6 s majors dominate. Any window shorter than the longest pause has
MMU 0.

**GC work outside the legacy minor timer:** stack walk 0.20 s and large-body sweep 0.005 s per run,
both previously counted as mutator time.

## 4. Minor-pause anatomy

The minor pause totals 61.2 s per run (median). Shares are the median of three runs; r1–r3 agree
to about 0.2 pt.

| phase | total | share | per minor |
|---|---|---|---|
| stack walk | 0.20 s | 0.33 % | 0.10 ms |
| roots: long-lived + JIT | 0.005 s | 0.01 % | 0.002 ms |
| roots: stackmap | 0.005 s | 0.01 % | 0.003 ms |
| roots: ranges + singles | 0.003 s | 0.00 % | 0.001 ms |
| roots: external scanners | 1.09 s | 1.78 % | 0.57 ms |
| **drain: to-space (Cheney)** | **29.39 s** | **48.0 %** | 15.3 ms |
| **drain: promoted objects** | **30.64 s** | **49.9 %** | 15.9 ms |
| tail (grow/clear/swap) | 0.001 s | 0.00 % | — |
| large-body sweep | 0.005 s | 0.01 % | — |
| **unaccounted** | 0.004 s | **0.01 %** | — |

The unaccounted residual is well under the 2 % acceptance line, so no phase is missing. Drain
rounds are 1 in every minor: the Cheney ↔ promoted fixed point never needed a second round.

### 4.1 What share of the minor pause is promotion?

The two drain loops interleave the two kinds of copy, because each loop both copies and promotes,
so the split is derived.

| Quantity | Value |
|---|---|
| Promotion allocator, sampled 1-in-256 with clock overhead removed (21–22 ns per bracket calibrated) | **21.8 s, 32.2 ns per promotion** |
| In-pause lazy sweep, sampled 1-in-16 | **2.23 s** (10.5 GB swept inside minors, 2,416,644 slices) |
| Mean drain cost per copied object | **41.4 ns** (to-space + promoted, 1.42 B objects) |

- Taking the memcpy-and-scan part of a copy as equal for both kinds, a to-space copy costs
  **≈ 25 ns** and a promotion **≈ 61 ns** (25 + 32 allocator + 3.3 sweep).
- **So promotion is ≈ 67 % of the minor pause** (676 M × 61 ns ≈ 41 s of 61 s).
- `design_docs/parallel-gc.md` §1 estimated 75–80 % (±30 %) from a counter differential. The
  measurement lands just below that range.
- The 67 % is if anything a lower bound: an age-1 promoted object is colder than an age-0
  survivor, so its copy likely costs more than 25 ns.
- **The old-gen allocator's own work (free-list pop, split, bag page) is ~36 % of the minor
  pause, on the mutator.** It is the single largest identifiable item. Phases 2 and 6 of the
  master plan target exactly this.

### 4.2 Stack and roots

- **Stack walk:** mean 108.6 frames, max 1127; matched 90.4 frames on average; mean 202 slots,
  max 10,068; **0.10 ms per minor, max 0.31 ms.** That is 0.33 % of the minor pause. The
  generational stack watermark (master-plan phase 8) is **not** justified on this workload.
- **External scanners** (median run):

  | scanner | total | mean per minor | slots | max slots in one minor |
  |---|---|---|---|---|
  | `cellstore` | 835 ms | 434 µs | 89,044,640 | **1,302,037** (max 8.6 ms in one minor) |
  | `mvar` | 161 ms | 84 µs | 1,648,077 | 1,030 |
  | `scheduler` | 71 ms | 37 µs | 1,388,155 | 976 |
  | `list-scratch` | 3.6 ms | 1.9 µs | 42,587 | 17,407 |
  | `platform-runtime` | 2.5 ms | 1.3 µs | 57,720 | 30 |
  | `eco-runtime`, `time-effects` | < 1 ms | — | 0 | 0 |

  `http` never registered on this workload: it registers lazily on first HTTP use. The timed runs
  had explicit names for `mvar` and `scheduler`. In the final binary those two are labelled from
  their registration address (plan §6a).

  CellStore is 77 % of external-root time: 0.8 s in total, but **up to 8.6 ms in a single
  pause**, from scanning 1.3 M cells. That is the root-scan floor that any concurrent nursery
  design (master-plan phase 7) cannot hide. A dirty-chunk scan (phase 8) would cut it, and it is
  worth it once the pause targets reach the ms range.

### 4.3 The worst pauses

From the event-log run; `benchmarks/gc-event-log-summary.py` part (d).

| at | pause | kind | contents |
|---|---|---|---|
| 110.4 s | 2608 ms | minor + major | major (mark-bound); the minor part was about 155 ms |
| 68.7 s | 2380 ms | minor + major | " |
| 40.0 s | 2091 ms | minor + major | " |
| 21.8 s | 1309 ms | minor + major | " |
| 113.1 s | **903 ms** | minor | promoted drain 829 ms; **3.77 GB lazy-swept inside the pause** |
| 10.5 s | 737 ms | minor + major | |
| 71.1 s | 680 ms | minor | promoted drain 602 ms; 2.83 GB swept |
| 42.1 s | 608 ms | minor | promoted drain 529 ms; 2.11 GB swept |
| 23.1 s | 390 ms | minor | promoted drain 324 ms; 1.14 GB swept |
| rest | 155–176 ms | minor | ordinary full minors: ~30–80 ms to-space + ~90–130 ms promoted drain |

- **The top five pause classes are the four majors, then four post-major sweep bursts.** Every
  minor above 200 ms is the first minor after a major, doing the lazy sweep of the whole old gen
  inside its promotions. This matches W7's 986 ms finding.
- Master-plan phase 2 (bitmap allocation) removes the bursts. Phases 4–5 remove the majors.
- Pearson r of minor pause against promoted = 0.84, survived = 0.83, lazy-sweep bytes = 0.53,
  stack slots = 0.24. Survivor volume drives the typical minor; sweep drives the tail.

### 4.4 A new lead: 4.9 M page faults inside minor pauses

`minflt` inside minors is **4,900,523 per run**, with 0 major faults. At 4 KiB per fault that is
**~18.7 GiB, about the promoted volume (19.4 GiB)**. So promotion appears to take a first-touch
fault on essentially every old-gen page it writes into. Old-gen blocks are
`madvise(DONTNEED)`-released on shrink (`DECOMMIT_ON_OLDGEN_RELEASE = true`) and refaulted on
reuse, and they are evidently not served by transparent huge pages.

The per-fault cost was not measured. At a typical 0.25–1 µs it is **1.2–5 s of minor pause**. This
was not visible before phase 0. It is a cheap single-threaded lead that is not yet in the master
plan: options are pre-faulting or `MADV_POPULATE_WRITE` for the next old-gen blocks, THP for
old-gen blocks, or not decommitting blocks that will be reused soon.

## 5. Survivor-write census (P1)

*(Filled from the heap-validate self-compile; see §5.1.)*

Heap-validate E2E suite with `ECO_SURVIVOR_WRITE_CENSUS=1` (G5): **0 mismatches**, 336 checked
(most E2E programs run in short-lived subprocesses), 1 builder object correctly skipped.

### 5.1 Self-compile census

`bin/eco-optT00v`: `ecoghash.mlir` lowered by the heap-validate tree's `eco-boot-native`, run
with `ECO_SURVIVOR_WRITE_CENSUS=1 ECO_VALIDATE_FREELIST_DUP_SCAN=0`.

- **First attempt** (duplicate-push scan on): stopped after 22 min, still inside the first
  post-major lazy sweep. The pre-existing O(list length) scan per free-list push makes a
  validator self-compile days long (plan §6a.6).
- **Second attempt** (scan off): ran **36 min**, through **1,389 of 1,924 minors (72 %) and all 6
  majors including their post-major sweeps**, with **zero validator reports**. That includes the
  existing `in_phase3_` "child of promoted object younger than promotion_age" assertion, which
  fires on the writes-of-younger-values subset of P1.
  - It was stopped by decision (2026-09-24): the validate build's footprint reached 14.6 GB on the
    15 GB box and was swapping, and a validator run at this workload size is too slow to be
    useful. Under that decision, no errors to the point of stopping counts as a pass.
  - **Limitation:** the census tally is printed by an `atexit` handler. The SIGTERM path prints the
    GC banner and re-raises, so no `[survivor-write-census]` table was produced for the
    self-compile. For phase 7a, a periodic or signal-safe census dump should be added.

**Verdict for phase 7a (P1):** no evidence of any write into a survived object.
- The E2E suite census: 0 mismatches.
- The self-compile validator: 0 young-child-of-promoted reports over 72 % of minors.
- A full-scale census count is still owed. Obtain it with a census build that is *not*
  heap-validate: census alone is linear and cheap.

## 6. Co-runner interference (Step 12)

`benchmarks/l3-corunner.sh`: the mutator is pinned to CPU 2 and the co-runner to CPU 10, which are
distinct physical cores on the same socket. Three cold runs per arm; every run's output was
identical to `ecoghash.mlir`.

| arm | co-runner | wall (median) | true mutator (median) | vs A |
|---|---|---|---|---|
| A | none | 182.97 s | **113.57 s** | — |
| B | collector-like: 350 K dependent-load 40 B copies every 59 ms (busy 81 %) | 171.67 s | **104.97 s** | **−7.6 %** |
| C | same, never sleeps | 170.23 s | **103.49 s** | **−8.9 %** |
| D | busy core, **no memory traffic** (`--spin`) | 188.76 s | **116.35 s** | **+2.4 %** |

Run-to-run spread within an arm is ≤ 0.7 s of mutator time. The effects are far outside it.

**Reading:**
1. **A co-runner generating memory traffic made the mutator faster, not slower.** A busy core
   *without* memory traffic (D) made it slightly slower, consistent with a shared power/turbo
   budget.
2. So the B/C speed-up is caused by the memory traffic itself. The most plausible mechanism is
   uncore/mesh frequency scaling: the uncore clocks up under memory load, which lowers LLC/DRAM
   latency for a latency-bound mutator. **Hypothesis, not verified**: the uncore frequency was not
   read.
3. Any L3-pollution penalty is smaller than that benefit on this machine.
4. **Caveat, as the plan requires:** the co-runner achieved **~135 ns per object**, not the
   collector-like ~40 ns. Its random walk over 512 MiB misses DRAM on every step, whereas a real
   copying collector has partial locality. The experiment bounds interference from a
   *memory-heavy* neighbour. It does not model the collector's exact access pattern.
5. **Pinning alone helps.** Arm A (pinned, 182.97 s) is ~2 s faster than the unpinned runs
   (~185 s).

**Implication for phases 5b, 6 and 7:** the feared cost of a concurrent GC thread, that it slows a
latency-bound mutator through the shared L3, did not appear on this machine. The first-order
effect of a memory-busy neighbour was a speed-up. Re-check with the real collector thread once one
exists: the interference line in §10 of the report stays a required measurement, just not a
blocking worry.

## 7. Final binary check

The final `eco-optT00` (re-lowered after the scanner-label restore) was run once more: see §7.1.

### 7.1

`eco-optT00final-r1`: `out.mlir` **byte-identical** to `ecoghash.mlir`. Wall 187.56 s, 1924
minors, 6 majors, 19,861 MiB promoted, allocated 254,094,395, promoted 675,767,781, **identical to
the same-session control**.

The address-labelled scanners appear as `unnamed@+0x2070343`, `unnamed@+0x2074a43` and
`unnamed@+0x207a1fb`. `nm -C bin/eco-optT00` resolves them to
`Eco::Kernel::MVar::registerGcRootScanner()`, `Eco::Kernel::Runtime::registerGcRootScanner()` and
`Elm::Platform::Scheduler::Scheduler()` respectively. Their per-minor costs match the named
figures in §4.2.

## 8. Gates

| gate | result |
|---|---|
| G1 runtime unit tests | 1734 / 1734 (main tree, including the 5 new tests: `EnsureHeadroomEndBelowPtr`, `GCPauseStats{MMU,Percentiles,Combine}`, and the validate-only `SurvivorWriteCensus`) |
| G2 Elm unit tests | 13,565 pass / 12 fail, the same 12 pre-existing failures as the reference |
| G3 E2E (`--target full`, clean rebuild) | **1734 / 1734** |
| G4 GC-pressure stress | **100 / 100 at 1,263 minor cycles**, so not vacuous |
| G5 heap-validate tree | test binary **1735 / 1735** (includes `SurvivorWriteCensus`), census on: 0 mismatches. The first attempt showed 63 codegen failures, all `sh: build/runtime/src/codegen/ecoc: not found`: the validate test binary calls the **main** tree's `ecoc` by relative path, and the main tree was mid-`full` (clean). It passed when re-run alone |
| G6 parser compatibility | **PASS**: `heap-profile.py parse_summary` and `lss-loop-extract.sh` extract every field, and the counter fields are equal to the same-session control |
| G7 stats-off build | the `release` preset cannot be configured on this box (static musl toolchain absent, pre-existing). A `-DECO_GC_STATS=OFF` tree builds; `nm` shows no instrument symbols referenced by `NurserySpace`/`ThreadLocalHeap`/`OldGenSpace` |
| G8 overhead | **PASS**: +0.77 s GC (+1.1 %), inside the noise (§2) |
| G9 determinism + fixed point | **PASS**: all runs' `out.mlir` byte-identical to `ecoghash.mlir` |
| LSS_022 kernel-license manifest | **PASS**: the four licensed kernel files are byte-identical to before the phase |

## 9. Implications for later phases

1. **Promotion is the target (confirmed).** ≈ 67 % of the minor pause, and the old-gen allocator
   alone ≈ 36 %. Master-plan phase 2 (bitmap allocation / promotion buffers) is well aimed, and
   it is also the prerequisite of phases 6 and 7.
2. **The worst pauses are majors (≈ 2.6 s), then post-major sweep bursts (0.4–0.9 s).** This
   confirms the pause-first ordering: phase 2 kills the bursts, and phases 4–5 the majors. MMU is
   0 up to 2 s windows today.
3. **The stack walk is negligible** (0.1 ms per minor, ≤ 1127 frames). The phase 8 stack
   watermark is not needed for this workload.
4. **The CellStore root scan** is up to 8.6 ms per pause. It sets the floor for concurrent nursery
   designs. The phase 8 dirty-chunk scan becomes relevant once other pause components are
   sub-10 ms.
5. **Interference is not a blocker.** A memory-heavy co-runner sped the mutator up by ~8 % on
   this box.
6. **New lead:** 4.9 M first-touch page faults inside minors, one per promoted 4 KiB. Consider
   folding pre-faulting/THP/decommit policy into phase 2.
