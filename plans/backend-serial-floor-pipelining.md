# Backend Serial-Floor Pipelining & MLIR Parallelization

## Implementation status (2026-07-07)

| Phase | Status | Measured effect (self-host, dev mode unless noted) |
|---|---|---|
| 0 instrumentation + overlapped split dispatch | ✅ | sub-phase stats live; workers dispatched as bitcode lands (drain 6.1 s vs 85 s worker CPU) |
| 1 nested tail conversions | ✅ **safe subset** | MLIR lowering 11.1 → 9.5 s. Stock `SCFToControlFlow` + `ArithToLLVM` nested on `LLVM::LLVMFuncOp` (parallel sweep). ⚠ The fused custom conversion (`Passes/EcoTailConversions.cpp`) is **PARKED** — it caused Heisenbug memory corruption (garbage `std::function` captures in the JIT path, 176/288 codegen failures even single-threaded); see the file header. cf→llvm stays module-anchored (stock). |
| 2 prologue→split→workers{RS4GC→opt→emit} | ✅ | **backend 30.7 → 22.4 s, total 51.3 → 41.7 s, CPU 337 %** (cgu: → 42.1 s). RS4GC serial 4.2 s → 3.2 s summed across 16 workers (hidden); cheap-IPO 5.6 → 4.2 s (statepoint-free input); split+serialize 14.75 → 12.15 s. `none` mode untouched (RS4GC-first preserved). RS4GC-dump flags force the whole-module path. |
| 3 pass micro-opts | ✅ (1+2 of 3) | **EcoPAPSimplify 1.0 s → 72 ms** (seeded `applyOpPatternsGreedily` over just the PapExtendOps); `containsNestedStringCase` memoized (listener-evicted; EcoCFToSCF 1.29→1.23 s — most of its cost is cloning, item 3 not taken). MLIR lowering 10.15 → 9.46 s. |
| 4 partition-count re-tune | ✅ measured, keep 16 | `--split-codegen=24` (dev): backend 23.7 vs 23.05 s at 16 — split+serialize grows with N (12.6 → 15.6 s; one `CloneModule` pass per partition) and eats the extra worker parallelism. Auto cap stays `min(cores,16)`. |
| 5 single-serialize + lazy extraction | ✅ **default-on** (`--lazy-split=0` reverts) | **serial split 12.15s → 1.32s** (externalize+serialize once); per-worker lazy extract 2.3s summed/16 (proves only 1/N bodies materialize). **dev backend 22.4 → 12.3s, total 41.7 → 31.0s, CPU 425%.** `Function::deleteBody()` on a not-yet-materialized function strips it to an extern decl without loading the body (LLVM's `convertToDeclaration` pattern); non-owned globals `setInitializer(nullptr)`. Membership = stable FNV-1a(name)%N (reproducible, unlike llvm::hash_value). eco module has 0 aliases/comdats/ifuncs so membership is a clean per-name hash. Validation: see below. |
| 6 frontend overlap | ✅ **measured, closed: no-go** | PhaseMlir = **20.3 s of 278.6 s** frontend (~7 %). K-unit pipelining ceiling ≈ 20 s on a ~330 s pipeline for a large cross-language change — below the ~30 s threshold. Single-module chunked `Bytes` transport rejected outright (no incremental bytecode parse; head tables written last). |

**Cumulative (dev): total 51.3 → ~31.0 s with `--lazy-split`** (vs 86.5 s
pre-parallel-opt, vs 224 s at the start of the backend perf work — a **7.2×**
backend speedup overall). Backend 30.7 → 12.3 s. Functional gates, all green:
- codegen suite: failure set IDENTICAL to stock baseline (271 pass / 9 pre-existing
  standalone-harness issues — same set under the untouched stock pipeline);
- AOT elm-core sweep (serial, fresh cache): **dev 99/99, cgu 99/99, 0 backend
  failures**;
- self-host equivalence: none/dev/cgu binaries produce byte-identical functional
  output (`--help` incl. GC allocation profile; only timing stats differ);
- JIT E2E (test/test, exercises the changed EcoPipeline via EcoRunner): **1547/1547**.
- **Phase 5 lazy split** (`--lazy-split`): nm defined-symbol set **byte-identical** to
  the SplitModule path (dev + none); **0 duplicate definitions** in any lazy binary;
  self-host `--help` functional output **identical** across none/dev/cgu, lazy vs
  non-lazy; AOT elm-core **dev 99/99, cgu 99/99**, 0 backend failures. The 2.3s
  per-worker extract (summed over 16) confirms only ~1/N bodies materialize.

Follow-up to `plans/parallel-llvm-opt-partitioning.md` (parallel-opt tiers, shipped).
Attacks the remaining **serial floor** of the AOT backend and pipelines the stages
that still gate wall-clock. Investigation completed 2026-07-06 (three code sweeps:
MLIR-21 pass/bytecode internals verified against `/opt/llvm-mlir` headers; eco pass
hot paths; frontend emission structure).

## Measured baseline (instrumented, self-host module, 24 cores, `--lowering-stats`)

New sub-phase instrumentation (this plan's Phase 0) reveals where the wall goes.
All three modes, one run each:

| serial phase (wall s)              | none  | dev   | cgu   |
|---|---|---|---|
| MLIR lowering pipeline             | 10.95 | 11.07 | 11.20 |
| MLIR → LLVM IR translation         | 5.59  | 5.65  | 5.69  |
| Internalize + GlobalDCE            | 0.37  | 0.38  | 0.38  |
| RS4GC + frame-pointers (serial)    | 4.17  | 4.23  | 4.28  |
| whole-module O2 / cheap-IPO        | 38.52 | 5.61  | 5.88  |
| **split + bitcode serialize (serial)** | **17.07** | **14.75** | **15.73** |
| parallel opt+emit drain (post-split)   | 4.50  | 6.11  | 6.87  |
| Link                               | 1.00  | 1.03  | 0.73  |
| backend total                      | 64.26 | 30.71 | 32.76 |
| **wall total**                     | 84.6  | 51.3  | 53.3  |

Worker CPU sums (dev): partition opt 16.8 s + partition emit 68.1 s across 16
threads — mostly hidden behind the split thanks to the overlapped dispatch (Phase 0).

**The dominant serial item is `SplitModule` + per-partition bitcode serialization
(~15-17 s)** — N× `CloneModule` + N bitcode writes on the parent thread — bigger
than the whole MLIR pipeline. Second tier: cheap-IPO prologue (5.6 s, runs on
statepoint-bloated IR) and RS4GC (4.2 s serial).

## Investigation findings (evidence in the agent sweeps; key file:line cites inline)

1. **MLIR tail conversions are parallelizable.** After `EcoToLLVMPass`, functions
   are `LLVM::LLVMFuncOp` (`EcoToLLVM.cpp:201,284`). Verified against MLIR 21
   headers: `SCFToControlFlowPass`, `ArithToLLVMConversionPass`,
   `ReconcileUnrealizedCastsPass` are **any-op anchored** (`Conversion/Passes.td:1004,174,979`)
   → nestable via `addNestedPass<LLVM::LLVMFuncOp>`. `ConvertControlFlowToLLVMPass`
   is ModuleOp-anchored **only because of the `cf.assert` pattern** (inserts a
   module-level global via `createPrintStrCall`); eco emits no `cf.assert`, and
   `cf::populateControlFlowToLLVMConversionPatterns` excludes the assert pattern
   (`ControlFlowToLLVM.h:33-38`) → a ~30-line custom function-anchored pass is safe.
   **Adjacent nested passes merge into ONE parallel sweep** (`OpToOpPassAdaptor::
   tryMergeInto`, `failableParallelForEach` over the context thread pool). ~3.6 s of
   module-serial pass time at stake. Keep a final module-level reconcile for any
   module-scope casts (global initializer regions).
2. **Per-partition RS4GC is safe.** `addEcoGCPipeline` = per-function
   mem2reg/SROA/FoldExtractValue + `RewriteStatepointsForGC`
   (`EcoPtrIntVerify.cpp:448-476`); RS4GC iterates functions independently and
   consults only callee-declaration attrs (`gc-leaf-function`) and the per-function
   `gc "eco-gc"` attr — both preserved by CloneModule into partitions. The
   frame-pointer walk is per-function. So the pipeline can run *inside each
   partition worker* instead of whole-module.
3. **The cheap-IPO prologue (IPSCCP/GlobalOpt/function-attrs/GlobalDCE) can move
   before RS4GC.** None of these do intra-function code motion across calls (the
   REP_LLVM_001(a) hazard mechanism — hoisting a `ptrtoint ptr<1>` across a
   to-be-statepoint call — needs InstCombine/GVN/LICM-class motion, which the
   prologue does not contain). Running it pre-statepoint shrinks its input IR and
   lets RS4GC move into the workers. Gate: full E2E + GC-heavy AOT tests (+
   `ECO_LOWERING_VALIDATION`/`EcoPtrIntVerify` sign-off before default).
4. **Bytecode streaming-parse is impossible** — `BytecodeReader` requires the
   complete buffer (`BytecodeReader.h:33-48`); no push parser exists. Single-module
   chunked `lowerAndLinkBytes` transport therefore buys **nothing** (the backend's
   first action needs the last byte). Worse, the *bytecode* writer assembles
   head-of-file tables **last** (`StreamEncode.elm:116-168`), so the frontend
   cannot even stream a single module front-to-back.
5. **Real frontend/backend pipelining = K-unit chunked emission** (frontend emits K
   self-contained MLIR modules, backend lowers unit k while the frontend generates
   k+1). Feasible: the emission walk is deterministic SpecId-order, per-func value
   numbering is chunk-local, signatures for cross-chunk extern decls are
   precomputed (`Backend.elm:266-267`); blockers are routing the type table/main/
   kernel decls to the final chunk + a chunked kernel transport. **Ceiling =
   `min(PhaseMlir, backend)`** — PhaseMlir (the `MLIR codegen` row of
   `eco make --stats`) has never been measured; measure before building.
6. **Micro-opts worth taking** (agent-verified): `EcoPAPSimplify` wastes ~0.9 s in
   the greedy driver seeding all ~12 MB of ops for two papExtend-local patterns
   (`EcoPAPSimplify.cpp:292`) — restructure as one walk + local worklist + explicit
   DCE. `EcoControlFlowToSCF` re-walks whole subtrees in
   `containsNestedStringCase` on every greedy re-attempt (`:105-112`; called at
   `:163,:367,:545`) — memoize (~0.2-0.4 s); alternative-cloning → region-move is a
   further ~0.3-0.5 s if still hot.
7. **Dead ends (do not retry):** B1 per-function re-anchoring of
   GCPrepare/Joinpoint/RCElim (implemented before, measured neutral, reverted —
   `EcoControlFlowToSCF.cpp:1076-1081`); B3 parallel per-function EcoToLLVM
   conversion (feasible — all 9 module-artifact sites are pre-scannable — but
   weeks of GC-adjacent work for ≤4 s; first profile the `CallOpLowering`
   per-call O(module) symbol scan noted at `EcoToLLVM.cpp:280-284`); translation
   (5.6 s) is single-threaded by design (parallel translation would need MLIR-level
   module splitting — deferred with B3).

## Phases

### Phase 0 — Instrumentation + overlapped split dispatch ✅ (done during investigation)

- `EcoBackendJob.stats` (LoweringStats*) plumbed from both drivers; sub-scopes for
  RS4GC, prologue/whole-O2, split+serialize, drain, per-worker opt/emit sums.
- `emitObjectFilesSplit` now **dispatches each partition's worker as soon as its
  bitcode is serialized** (was: serialize all N, then spawn all N). Drain after
  split is 4.5-6.9 s vs 68-99 s of worker CPU — overlap works.
- ⚠ One-sample wobble vs the pre-change run (dev backend 30.7 vs 28.7 s) — within
  clean-rebuild noise, but A/B once during Phase 2 timing (workers competing with
  the serializing parent for bandwidth is a plausible ~1-2 s cost; the overlap is
  still structurally right once the split payload shrinks in Phase 2).

### Phase 1 — Nested parallel tail conversions (MLIR)

In `EcoPipeline.cpp` replace the module-anchored tail
(`SCFToControlFlow`, `ConvertControlFlowToLLVM`, `ArithToLLVM`,
`ReconcileUnrealizedCasts`; ~3.6 s serial) with:

1. New `Passes/EcoCFToLLVM.cpp`: function-anchored pass (`OperationPass<LLVM::LLVMFuncOp>`)
   applying `cf::populateControlFlowToLLVMConversionPatterns` (assert-free).
2. `pm.addNestedPass<LLVM::LLVMFuncOp>(createSCFToControlFlowPass())`
   + nested custom cf-to-llvm + nested `createArithToLLVMConversionPass()`
   + nested `createReconcileUnrealizedCastsPass()` — adjacent → one parallel sweep.
3. Keep one final module-level `ReconcileUnrealizedCastsPass` (module-scope casts).

Validation: codegen suite (`TEST_FILTER=codegen … full`), JIT E2E; timing run.
Expected: MLIR lowering 11 → ~8 s.

### Phase 2 — Reorder: prologue → split → per-partition {RS4GC → opt → emit}

For `parallelOpt != None` (exe path) change `runEcoBackend` order from
`RS4GC → cheap-IPO → split → workers{opt,emit}` to:

`internalize+DCE → cheap-IPO (pre-statepoint, whole-module) → split →
workers{addEcoGCPipeline+FP → opt → emit}`.

- Moves 4.2 s RS4GC + FP walk into the 16-way workers.
- Prologue runs on statepoint-free IR (smaller/faster; expect 5.6 → ~3-4 s).
- Split serializes statepoint-free bitcode (expect 14.75 → ~10-12 s).
- `None` mode is untouched (whole-module O2 keeps today's RS4GC-first order).
- Guard: `deferRS4GC` (`--rs4gc-after-opt`) remains incompatible with parallel
  modes. The dumps (`--dump-*-rs4gc-ir`) fall back to whole-module RS4GC-first
  behaviour when requested (diagnostic paths shouldn't silently change).

Validation: full E2E + JIT + AOT elm-core sweep under dev+cgu; GC-heavy tests;
timing (expect dev backend ~30.7 → ~20-23 s). Risk note: finding 3; if any GC
regression appears, fall back to RS4GC-before-prologue whole-module (keeping only
the smaller win of per-partition RS4GC after a statepoint-aware prologue).

### Phase 3 — Pass micro-opts (MLIR)

1. `EcoPAPSimplify`: one `module.walk` collecting `PapExtendOp`s; per-item apply
   saturated-call then chain-fusion patterns with a small local worklist (fused ops
   re-tried); explicit cascade-DCE of dead `papCreate`/`papExtend`; keep the
   prebuilt `SymbolTable` (read-only). (~0.8-0.9 s)
2. `EcoControlFlowToSCF`: memoize `containsNestedStringCase` (pre-pass post-order
   "poisoned" set or lazy DenseMap + erase-listener). (~0.2-0.4 s)
3. (Only if still ≥1 s after 1-2) alternative-clone → `inlineRegionBefore` for the
   two case patterns.

Validation: pap_*/case_*/joinpoint_* codegen tests + full E2E; timing.

### Phase 4 — Partition-count re-tune (config)

After Phase 2 shrinks the serial region, re-measure `--split-codegen=16` vs `=24`
(= cores) for dev/cgu. If ≥5 % better, raise the auto cap for parallel-opt modes
(`choosePartitionCount`: `min(cores,16)` → `min(cores,24)` or `cores` when
`parallelOpt != None`). Keep 16 for emission-only (`none`) — measured regime.

### Phase 5 (stretch) — Single-serialize + lazy per-worker extraction

Replace `SplitModule` (N× CloneModule + N bitcode writes, all serial) with:

1. Parent: externalize all locals (SplitModule's `PreserveLocals=false` semantics,
   single definitions) → **one** `WriteBitcodeToFile` of the whole module.
2. Workers: `getLazyBitcodeModule` over the shared buffer (own LLVMContext);
   deterministic membership (hash(name) % N, computed identically in each worker);
   `materialize()` own functions; drop other bodies to declarations;
   `materializeAll` guard; then RS4GC → opt → emit as in Phase 2.

This is the ThinLTO-importer pattern (lazy source modules + selective
materialization). Risk: `deleteBody()` interaction with unmaterialized lazy
functions — validate on a 2-partition micro-module first; if the lazy path fights
back, fall back to eager `parseBitcodeFile` per worker (still deletes the N×
CloneModule serial cost; parse is parallel). Expected: split serial 14.75 → ~3-5 s.
Gate: byte-identical output vs Phase-2 split on a mid-size module, then full E2E.

### Phase 6 — Frontend overlap: measure, decide, design

1. **Measure PhaseMlir**: run the self-compile with `--stats`
   (`eco-compiler make --optimize … --stats`) and record the `MLIR codegen` row
   (plus the untimed artifact-load gap). This is the hard ceiling for K-unit
   pipelining (finding 5).
2. Record the decision: if PhaseMlir ≥ ~30 s, write the K-unit chunked-emission
   follow-up plan (frontend: per-chunk fresh StreamTables + synthesized cross-chunk
   extern decls from the precomputed signature array + per-chunk lambda drain +
   type-table/main/kernel-decls in the final chunk; kernel transport:
   `lowerAndLinkBegin/AddModule/Finish`; backend: lower each chunk as it arrives —
   the multi-object link + multi-blob stackmaps already exist). If < ~30 s, record
   "not worth the cross-language complexity" and close.
3. Single-module chunked `Bytes` transport (the original `lowerAndLinkBytes`
   streaming idea): **rejected** — finding 4 (no incremental parse; bytecode
   format assembles head tables last). Recorded here so it isn't re-proposed.

## Explicitly out of scope (with reasons)

- B1 re-anchoring of per-function eco passes — measured neutral previously; the
  hot passes are algorithmically bound, not anchor-bound (finding 7).
- B3 parallel per-function EcoToLLVM dialect conversion — pre-scannable but weeks;
  profile `CallOpLowering`'s O(module) symbol scan first (finding 7).
- Parallel MLIR→LLVM translation via MLIR-module splitting — legal (verified) but
  needs the same module-splitting machinery as B3; revisit together.
- A4 GC-liveness backward sweep — ≤0.4 s, GC-critical; only if EcoGCPrepare grows.

## Success criteria

- Each phase lands behind green codegen + E2E (+ AOT sweep for Phase 2/5) runs.
- Instrumented before/after timing recorded per phase in `backendstats-runs.txt`.
- End state (dev): backend ≤ ~20 s, total ≤ ~40 s (from 30.7 / 51.3 today);
  `none` mode unchanged within noise.
