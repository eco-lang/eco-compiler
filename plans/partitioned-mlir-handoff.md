# Partitioned MLIR hand-off: overlap native lowering with front-end codegen

**Status:** OUTLINE (2026-10-03). Not started.
**Reopens:** `plans/backend-serial-floor-pipelining.md` Phase 6 ("K-unit chunked emission"),
closed as no-go on 2026-07-07 when MLIR codegen was 20.3 s of a ~330 s pipeline.
**Builds on:** the MLIR split series (`plans/mlir-split-backend.md`, children 01-07).

## 0. Problem

A cold Stage 9b self-compile (`eco` → `eco-2`, measured 2026-10-03 after the fe-opt-loop) takes
86.6 s:

| stage | wall | cores in use |
|---|---:|---:|
| front end up to MLIR codegen (parse/check/build, typed-graph load, mono, inline, global opt) | 53.2 s | 1.1–1.5 |
| **MLIR codegen** (Elm IR generation + bytecode write) | **12.0 s** | **1.1** |
| MLIR hand-off: parse + verify | 1.4 s | 0.8 |
| MLIR lowering pipeline (Eco passes, EcoToLLVM, reachability, cap-hoist, gc-free) | 4.1 s | 11.3 |
| EcoSplit + 24 parallel partitions (translate, RS4GC, LLVM opt, codegen) | 13.9 s | 23.0 |
| link | 1.3 s | — |

During the 12 s of MLIR codegen, 23 of 24 cores are idle. Then the back end runs about 21 s,
mostly CPU-bound (312 core-seconds in the partition stage), and it can only start after the last
byte of the module is written:

1. **The bytecode format.** Every op refers to strings, op names, attributes and types through
   file-wide tables. MLIR's `BytecodeReader` takes one complete buffer, and eco writes the tables
   after the last op (`StreamEncode.elm:131-173`). So no prefix of the file is readable.
2. **The hand-off.** A single temp file goes to `Eco.NativeDriver.lowerAndLink` once
   (`Terminal/Make.elm:394-483`), followed by an eager `parseSourceFile`.
3. **Whole-program passes.** `EcoReachability`, `EcoCapHoistPlan`, `EcoGcFreePropagation` and
   EcoSplit's partition planning (plans 01, 02, 03, 05) need the closed world. Their results
   (linkage, `covered`/budget, gc-leaf attributes, `$cap` copies) change how every partition is
   lowered.

Fixing (1) and (2) alone (chunked transport of one module) is useless. Phase 6 of the serial-floor
plan already rejected it, and that stays rejected. (3) is the blocker the July design did not have,
because plans 01-03 came later.

## 1. Idea

Move every whole-program decision the back end needs into the Elm front end, which already holds
the monomorphized whole-program graph. Then emit the program as **K self-contained MLIR modules
(partitions)**, each one complete with its own tables, cross-partition extern declarations, and
the whole-program facts as attributes. Hand each partition to a native worker pool **as soon as it
is encoded**, while Elm goes on generating the next. Link all objects at the end (the multi-object
link and the multi-blob stackmaps already exist).

The MLIR whole-program passes stay, but as **validators**: in validate builds they recompute the
facts and require the front-end attributes to match. This is the same twin pattern plans 01 and 02
used against the LLVM path.

**Ceiling (estimate, Phase 0 replaces it with a measurement):** about 21 s of back-end work starts
at codegen start instead of codegen end. Work that fits on the idle cores during the 12 s window
disappears from the critical path. End-to-end wall from codegen start to link drops from about
31 s to max(12 s + last-partition latency, 312 core-s / 24 cores) + link, roughly 15–19 s.
**Expected saving 8–12 s (10–14 %) on a cold 9b.**

## 2. Scope

- In: executable output (`--output=<exe>`, `.o`), the in-process NativeDriver path, and
  `eco-boot-native` when given a partition set.
- Out: `--output=x.mlir` (stays one module), `.so`/`.node` (export contract, as in plan 03), the JS
  backend, JIT/`EcoRunner`.
- Unchanged: generated code quality (each partition already runs `-O2` on its own under the default
  cgu tier, so partitioning loses no cross-partition inlining it has today) and the bootstrap fixed
  points.

## 3. Phases

### Phase 0: measure and decide (no product change)

1. **Arrival profile.** Instrument `streamMlirBytecode` (`Backend.elm:302-414`) to log when each
   256-node batch is encoded, with byte counts, under an env flag.
2. **Partition latency.** Record per-partition lowering wall and CPU time from today's split
   (`ECO_SPLIT_WORKER_STATS`).
3. **Simulate.** Replay arrival against latency for K ∈ {24, 48, 96} with a 23-worker pool, to get
   the real ceiling.
4. **Fact census.** List every whole-program input each partition's lowering consumes: reachable
   set and linkage, `covered`/budget, gc-leaf, `$cap` `available_externally` copies, eval-descriptor
   identity, the type table, `main`/`__eco_init_globals`, kernel declarations, and the
   `eco-reach`/plan module flags. For each, record where it can come from in Elm and whether its
   input exists before MLIR emission. Re-read plan 03's placement results (placement B refuted)
   and plan 01's "seven LLVM-behaviour emulations" for facts that only exist after lowering.
5. **Gate:** GO if the simulated saving is at least 6 s and no fact in (4) is lowering-only, or each
   such fact has a sound conservative front-end bound.

### Phase 1: whole-program facts in the front end (single module, no partitioning yet)

- Compute reachability from `main`/`__eco_init_globals` over the **emitted symbol graph**, including
  the `$clo`/`$cap` variants codegen mints. Prefer to stop minting dead variants (plan 03 §12 Q1)
  over pruning them afterwards.
- Port the gc-free propagation fixpoint to Elm, using `KernelFacts` plus the shared marker
  may-GC table.
- Port the cap-hoist plan (budget/coverage fixpoint) to Elm, using the allocation sizes codegen
  already knows.
- Emit the results as the same attributes and module flags the MLIR passes write today. The MLIR
  passes then see "already planned" and run as validators (`ECO_*_VALIDATE=1` makes any mismatch
  fatal).
- **Accept:** byte-identical ELF against today; validators report zero mismatches on the
  self-compile, the E2E suite and AOT E2E; wall flat or better. This phase can land on its own,
  even if later phases stop.

### Phase 2: partitioned emission, handed over at the end (no overlap yet)

- **Partition plan in Elm:**
  - deterministic, balanced by an emitted-size estimate (LPT, as EcoSplit's C2 step does);
  - emission order chosen so that the partitions that take longest to lower are emitted first.
- **Per-partition `StreamTables`**, so each partition is a self-contained bytecode module.
- **Cross-partition extern declarations** synthesized from the precomputed signature array
  (`Backend.elm:266-267`).
- `$cap` bodies copied into the partitions that use them, as EcoSplit does today.
- **Per-partition lambda drain.** Today lambdas, `main`, kernel declarations and the type table
  are only emitted at the end (`finishBytecode`, `Backend.elm:417-473`). Route each to the
  partition that owns it, with the type table and `main` in a final small partition.
- **Back end** accepts a set of modules and skips EcoSplit's planning.
- **Accept:**
  - same defined-symbol set and same functional output as the single-module path;
  - zero duplicate definitions;
  - E2E, AOT E2E (902/904 expected), bootstrap 4b/8c;
  - wall time flat (this phase only rearranges work).

### Phase 3: asynchronous hand-off (the win)

- **Kernel API:** `Eco.NativeDriver.lowerBegin`, `lowerAdd`, `lowerFinish`.
  - `lowerAdd` copies the partition's bytes off the Elm heap and enqueues them, then returns at
    once. Worker threads never touch the Elm heap (single-mutator rule, CR-012 option F).
  - `lowerFinish` joins the workers, reports the first error, and links.
- Twins: the JS kernel and the `src-xhr` twin report "native lowering unavailable", as
  `lowerAndLink` does today.
- **Determinism:** link order and object names come from partition indices, never from completion
  order.
- **Accept:** the Phase 2 gates plus the Phase 0 ceiling largely realized.
- **Measure:** cold 9b wall, an aligned CPU timeline (the method from 2026-10-03), and peak RSS,
  since back-end contexts now coexist with the front-end heap.

### Phase 4: tune

- Choose K and partition granularity against the measured arrival rate and the worker count.
- Bound in-flight partitions to cap memory.
- Try lowering worker priority while the front end is still running.
- Optional: emit the hottest-to-lower partitions first.

### Phase 5: clean up

- Default on, with an escape hatch (`ECO_PARTITIONED_HANDOFF=0` falls back to single-module +
  EcoSplit).
- Decide whether the MLIR whole-program passes stay as validators or are deleted.
- New invariants (CGEN/REP rows) for "partition modules are self-contained", "whole-program facts
  are front-end computed", and "partition order is deterministic".
- Update `docs/bootstrap.md` and the Phase 6 note in the serial-floor plan.

## 4. Risks

| risk | consequence | mitigation |
|---|---|---|
| Front-end facts drift from MLIR semantics (especially gc-leaf, cap-hoist) | GC-critical miscompile | Validators in validate builds; Phase 1 ships alone behind byte-identical ELF |
| Facts that only exist after lowering (plan 01's LLVM-behaviour emulations) | Phase 1 can only approximate | Phase 0 census; conservative bounds; else stop after Phase 0 |
| Late-minted symbols (`$clo`/`$cap`, lambdas drained at the end) unbalance the last partition | Tail latency eats the win | Per-partition lambda drain (Phase 2) |
| Peak RSS: back-end contexts alongside the 6.5 GB front-end heap | OOM on small hosts | Bounded in-flight queue; measured in Phase 3 |
| CPU contention with front-end GC helpers | Front end slows down | Worker priority; measure GC time per phase |
| Nondeterministic object or link order | Breaks the bootstrap fixed point | Index-ordered objects; fixed-point gate |
| Cross-language complexity (the July objection) | Maintenance cost | Phase 1 delivers value on its own; Phases 2-3 only after the Phase 0 GO |

## 5. Success criteria

- Cold Stage 9b at least 6 s faster, and up to ~12 s; front-end phases unchanged.
- Bootstrap fixed points 4b/8c hold; E2E full pass; AOT 902/904; recursive-call tax unchanged.
- Peak RSS no worse than +10 % of today's 6.5 GB.
- `ECO_PARTITIONED_HANDOFF=0` reproduces today's pipeline exactly.
