# X6: Warm-build timing: where a no-change or one-edit rebuild spends its time

**Status:** run on 2026-10-06 in a bootstrapped copy of the tree (12-core container). Raw logs are in
`/tmp/inc-exp/results/x6/`. The added timers are in `experiments/x6-festats-timers.diff`, and the
runner in `experiments/x6-run.sh`.

**Question (01 §4, 07 §2):** fill in the timing gaps.
- typed-graph load, assign and pre-mono each timed separately;
- a warm `--stats` run;
- a warm build to an executable;
- the cost of `.ecot` decode;
- GlobalOpt broken out from the rest.

## Method

**New timers.** Two FEStats phases were added. `--stats` already times "inline + simplify" and
"global optimization".
- **typed-graph load:** loading package typed artifacts, then stream-loading and merging every
  cached `.ecot`.
- **assign mvar ids:** `EntryPrep.assign`.

Every phase row now also prints its start/end offsets, so untimed gaps become visible. The gap
between "assign" and "monomorphization" is the pre-mono passes.

**Runs.** The subject is the compiler's own source, built with the instrumented `eco` (unified
binary). Each run held the machine-wide lock, in this order for each target (`.mlir`, then the
native executable through the in-process NativeDriver):
1. cold (cache deleted);
2. warm with no change;
3. warm with a one-module edit: a string literal inside a function body of
   `Compiler/Generate/MLIR/Names.elm`, so the interface is unchanged;
4. warm again;
5. edit again;
6. cold again.

**Correction made while running.** An earlier attempt recopied `elm.json` before every run. That
bumps its mtime, and the project cache treats an `elm.json` mtime change as a full invalidation, so
the "warm" runs were silently cold. The runner now copies it once. Anyone measuring warm builds
must avoid touching `elm.json`.

## Results

### Front end, to `.mlir` (seconds)

| Phase | cold ×2 | warm ×2 | 1-module edit ×2 |
|---|---|---|---|
| parse / check / build | 24.3 / 25.3 | 0.05 / 0.05 | 0.05 / 0.05 (1 module rebuilt) |
| typed-graph load | 0.07 / 0.07 | 0.58 / 0.63 | 0.59 / 0.62 |
| assign mvar ids | 3.0 / 3.1 | 2.9 / 3.1 | 2.9 / 3.0 |
| pre-mono passes (gap) | 0.3 | 0.3 | 0.3 |
| monomorphization (solver + LSS) | 24.9 / 25.6 | 25.1 / 26.0 | 25.1 / 25.4 |
| inline + simplify | 0.88 / 0.83 | 0.84 / 0.85 | 0.84 / 0.84 |
| global optimization | 1.4 / 1.3 | 1.3 / 1.3 | 1.3 / 1.3 |
| MLIR codegen | 12.4 / 12.6 | 12.2 / 12.5 | 12.2 / 12.2 |
| **Total (process wall)** | **67.8 / 69.4** | **43.3 / 44.9** | **43.3 / 43.9** |

### To an executable (seconds; back end = total − end of MLIR codegen)

| Run | Front end to end of MLIR | Back end (temp write, pre-link GC, lowering, link) | Total |
|---|---:|---:|---:|
| cold 1 / cold 2 | 66.3 / 71.2 | 55.5 / 58.0 | 122.0 / 129.4 |
| warm 1 / warm 2 | 43.7 / 46.4 | 57.4 / 57.7 | 101.3 / 104.3 |
| edit 1 / edit 2 | 44.0 / 43.7 | 56.2 / 56.0 | 100.3 / 99.9 |

On this 12-core box the back end is about 56 s. The 2026-10-03 figures (~21 s of back end, 86.6 s
cold 9b) were taken on 24 cores.

## What this means

1. **A one-line edit costs the same as a no-change rebuild: ~43 s to MLIR, ~100 s to an
   executable here.** Today's incrementality ends at type checking. Parse/check/build drops from
   ~24 s to 0.05 s, and *everything after it reruns in full*.
2. **The whole-program part of a warm build, to MLIR (43 s):**

   | Part | Time | Share |
   |---|---:|---:|
   | monomorphization | 25 s | 58 % |
   | MLIR codegen | 12.3 s | 28 % |
   | assign | 2.9 s | 7 % |
   | GlobalOpt | 1.3 s | — |
   | inline | 0.84 s | — |
   | typed-graph load | 0.6 s | — |
   | pre-mono | 0.3 s | — |

   Then the back end adds ~56 s here (~21 s on 24 cores).
3. **Loading the typed program is cheap.**
   - Warm typed-graph load, i.e. decoding every cached `.ecot` plus package artifacts and merging,
     takes **0.6 s**. On a cold build it is 0.07 s because the modules are already in memory.
   - This settles the open ".ecot decode" question: it is not a bottleneck.
   - It also means a server that keeps the typed program in memory saves only ~0.6 s per build,
     which matches X8.
4. **Assign (3 s) is a whole-program pass** that numbers MVars, lambdas and arrows over the
   merged graph. It is also the source of the unstable input ids in 03. Making ids relative to
   their definition (03 §2.2) could make it per-module and cacheable.
5. **GlobalOpt (1.3 s) and inline (0.84 s) are small.** The whole-program costs worth attacking
   are, in order: back end, mono, MLIR codegen. That is the order in 07 §3.
6. **Corrections:**
   - **01 §3:** the "≈ 5.8 s" lump measures as typed-graph load 0.07 + assign 3.0 + pre-mono 0.3
     + inline 0.85 + GlobalOpt 1.35 ≈ 5.6 s on a cold build.
   - **05:** the typed state a server would keep is cheap to reload (see X8).

## Limitations

- One subject and one machine (12 cores). Back-end times are not comparable to 24-core figures.
- N = 2 per scenario. The one outlier (cold 2 to an executable, +7 s) coincided with other agents'
  light jobs.
- The edit was interface-preserving. An interface-changing edit would also re-check dependents,
  but this does not change the conclusion: everything after type checking already reruns in full.
