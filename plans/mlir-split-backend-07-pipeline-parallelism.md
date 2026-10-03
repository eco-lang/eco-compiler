# MLIR split backend 07: parallelize the serial MLIR pipeline

**Master plan:** `plans/mlir-split-backend.md` (§1 "pull serial work out of the MLIR lowering").
**Parent:** plan 06 (`plans/mlir-split-backend-06-partition-boundaries.md`), the reference tree
(snapshot `ref-P07`, loop entry B4X).
**Status:** IMPLEMENTED 2026-10-03: all of P0–P10 plus P4r (the P4 secondary). Every step is byte-identical: the lowered executable and the post-pipeline MLIR match the reference md5s. MLIR pipeline 8.02 → 2.74 s, wall 25.10 → 20.04 s. Results in "Implementation results" at the end.

`E2L` = `runtime/src/codegen/Passes/EcoToLLVM.cpp`; `P/` = `runtime/src/codegen/Passes/`.

## 0. Goal and evidence

The self-compile lowering of `stats-backend-opt/p04/base.mlir` takes 25.10 s wall. The MLIR
pipeline is 8.02 s of that: everything before EcoSplit forks its 24 workers, so every second of it is
a second on the critical path. The 2026-10-03 profile (perf with timeline slicing, plus 40 gdb
all-thread snapshots; data in `stats-backend-opt/prof/` and memory `mlir-pipeline-profile-oct3`)
found two separate problems.

**(a) Most of the pipeline runs on one thread.** 22 of 32 snapshots inside the pipeline had one
thread working and 24 idle. The serial stretches (measured 2026-10-03, `ECO_ECO2LLVM_STATS=1`):

| stretch | wall | what it is |
|---|---|---|
| parse + verify | 0.70 s | bytecode reader (single stream) — out of scope, §5 |
| ListTemplate | 0.42 s | three serial whole-module walks + a `getSymbolUses` use index |
| BFToLLVM | 0.13 s | a whole-module conversion driver for a handful of bf functions |
| E2L stage 1 | 0.07 s | recursive `module.walk<func::FuncOp>` + `lowerAllocGroups` |
| E2L stage 0 | 0.77 s | `applyFullConversion(module)`: the driver visits all ~4.2M ops to convert ~75k shells |
| E2L stage 2b | 0.78 s | pre-materialization: four serial whole-body walks, then serial artifact creation |
| E2L stage 4 | 0.50 s | the epilogue `for_each` over every function (GC strategy, CAF guards, CAF and string-literal diamonds, shadow roots) |
| E2L stage 5 | 0.69 s | global-root init + unused-decl strip (strip is parallel but lock-bound, below) |
| ListCursor | 0.40 s | a serial `m.walk<scf::WhileOp>` over the whole module (the rewrites are 0.04 s) |
| TailConversions straggler | ~1.4 s of 2.20 s | ONE function's SCF→CF lowering: snapshots sit in `RewriterBase::splitBlock` / `notifyOperationInserted` |

**(b) The parallel stretches are lock-bound.** In the parallel snapshots ~40 % of the threads were
blocked, on four locks:

| lock | where | cause |
|---|---|---|
| glibc malloc arena | ControlFlowToSCF (16/25 blocked), E2L stage 2, Tail | worker threads free ops the parser thread allocated; every such `free` takes the main arena's lock |
| MLIRContext attribute uniquer (write) | E2L strip (23/24), EcoSplit build (18), partition translate (22) | `Operation::getAttrDictionary()` builds and uniques a fresh `DictionaryAttr` for every op with properties (nearly always a miss ⇒ exclusive lock) |
| `ParallelDiagnosticHandler` order-ID mutex | CapHoistPlan (14/24), Reachability, GcFree | `parallelForEach`/`parallelFor` take it twice **per element** — ~75k elements per call |
| MLIR `PassInstrumentor` mutex | FoldProject (14/25) | the nested per-function pass runs ~57k times, each under MLIR's global instrumentation lock |

A tcache experiment (`GLIBC_TUNABLES=glibc.malloc.tcache_count=65000`) confirmed the malloc lock:
ControlFlowToSCF 0.24 → 0.06 s, pipeline 8.16 → 7.74 s, but RSS +2.1 GB and wall flat. The allocator
itself is out of scope (§5).

## 1. What is genuinely ordered

Only these orderings are real; everything else in §0 is serial by implementation:

1. **Bytecode parse** — one reader over one stream (§5).
2. **E2L stage 0 → pre-materialization barrier.** Pre-materialization reads other functions'
   *converted* `llvm.func` signatures (`getOrCreateSatEntry`, `usesArgsArrayConvention`), and
   stage 2 reads symbols through `runtime.symCache`, which must point at post-stage-0 ops. The
   barrier stays; the work on each side of it can be parallel.
3. **Deterministic module-level symbol creation.** `__eco_str_N`, `__eco_str_case_<id>_<i>`, wrappers,
   `$sat` entries and descriptors are created in program order with counters. Only the *creation*
   must stay in that order; finding the demand sites can be parallel.
4. **ListTemplate phase 2** rewrites call sites in other functions, so the rewrites stay serial.
5. **Whole-program solves** (reachability BFS, cap-hoist SCC, gc-free fixpoint) — tens of ms on
   precomputed summaries; not targeted.
6. **Top-level insert/erase** in the module block — serial, but O(changed ops).

## 2. Rules for this series

- The loop of `benchmarks/backend-opt-loop.md` (one lowering run per step, wall primary, amendment-1
  second WIN rule: target phase improved by > 3× its spread with wall not worse). Input
  `stats-backend-opt/p04/base.mlir`, output logged as `stats-backend-opt/P07-<id>.*`.
- **Byte-identity gate on every step** (new for this plan, cheap): the reference tree's lowered
  executable is byte-reproducible (md5 `60fb7e14f3c7485d47c6b035094530bc`, two runs), and so is the
  post-pipeline MLIR (`ECO_DUMP_LOWERED_MLIR=<file>`, md5 `6d0f526ed4d46007d3838d61fcbc55a4`, 313.7 MB).
  Every step in §4 is designed to change no output, so the measured run's executable must match
  that md5. If it does not, dump the MLIR to localize the difference; a step that changes output is
  reverted (or re-planned as codegen-changing, which none of these should be).
- Snapshots: `ref-P07` is the reference; `try-<id>` / `keep-<id>` per step.
- Correctness gates are batched at the end (§6), per memory `fast-iteration-defer-checks`.
- Read `design_docs/invariants.csv` (CGEN_*, FORBID_*) before touching E2L. None of these steps
  changes a representation, ABI or emitted op; they change only *how* the same IR is produced.

## 3. Steps, in order of payoff ÷ risk

| id | step | target | expected |
|---|---|---|---|
| P0 | `ECO_DUMP_LOWERED_MLIR` hook (diagnostic) | gate | — (done 2026-10-03) |
| P1 | FoldProject as a module pass; per-thread LoweringStats shards | PassInstrumentor + stats locks | −0.15 s |
| P2 | one chunked parallel helper for every per-element `parallelForEach` | diagnostic-handler lock | −0.3 s |
| P3 | symbol-reference collection without `getAttrDictionary` | uniquer write lock | −0.5 s pipeline + EcoSplit build |
| P4 | TailConversions: listener-free SCF→CF driver | the 1.4 s straggler | −1.3 s |
| P5 | ListCursor: parallel loop collection | 0.36 s serial walk | −0.35 s |
| P6 | E2L epilogue in parallel chunks | stage 4 | −0.45 s |
| P7 | E2L pre-materialization: one parallel demand collection | stage 2b walks; stage 1 walk | −0.3 s |
| P8 | E2L stage 0 sharded into scratch modules | stage 0 | −0.65 s |
| P9 | ListTemplate: parallel pre-scan + parallel use index | 0.42 s | −0.3 s |
| P10 | BFToLLVM converts only the functions that hold bf ops | 0.13 s | −0.12 s |

Sum of expectations ≈ −4.4 s of the 8.0 s pipeline (the steps overlap less than additively; target:
pipeline ≤ 4.5 s, wall ≈ 21–22 s).

## 4. Implementation specification

### P1. FoldProject as a module pass; per-thread stats

**Why.** `EcoFoldProjectPass` is `OperationPass<func::FuncOp>` added with `addNestedPass`, so the
pass manager wraps it in an `OpToOpPassAdaptor` that runs ~57k per-function invocations. Each one
calls the pass instrumentation `runBeforePass`/`runAfterPass` under MLIR's global
`PassInstrumentor` mutex, then our `StatsPassInstrumentation::finalize` takes `LoweringStats::mu_`.
**The full fix is to stop running FoldProject as a per-function nested pass under instrumentation.
Its per-function times summed across threads are also CPU time rather than wall time, so timing it
once at module level is more accurate anyway.** (Today's banner reports "EcoFoldProjectPass 1.12 s,
56,944 calls" — a CPU sum — while the adaptor's real wall is 0.18 s.)

**Change 1 — `P/EcoFoldProject.cpp`:**
- Make the pass `PassWrapper<EcoFoldProjectPass, OperationPass<ModuleOp>>`.
- Move today's per-function body into `static void foldFunction(func::FuncOp f, Counts &c)` (unchanged
  logic: program-order walk, deferred erase, census counters).
- `runOnOperation`: if `!foldEnabled()` return; collect the non-external `func::FuncOp`s of the module
  in module order; run `foldFunction` over them with the P2 chunk helper (`eco::forEachChunk`, below),
  accumulating census counts per chunk and adding them to the atomics once per chunk; print the
  census line ONCE after the parallel region (a strict improvement on today's racy running total).
- Serial fallback when the context is single-threaded (the helper does this).
- Safety: the work is function-local (projection folding inside one function; the only creation is
  an `arith.constant` inside the same block), exactly as under the adaptor, which ran these
  functions concurrently already.

**Change 2 — `runtime/src/codegen/EcoPipeline.cpp`:** `pm.addPass(eco::createEcoFoldProjectPass())`
instead of `addNestedPass<func::FuncOp>`. CSE (`ECO_MLIR_CSE=1`, off by default) stays nested.
Pass order is unchanged (still before EcoMarkGCLeafCalls / EcoGCPrepare).

**Change 3 — `runtime/src/codegen/LoweringStats.{h,cpp}`, per-thread commutative shards** (the
user's design): `record`/`recordPass` stop taking `mu_` on the hot path.
- `struct Shard { llvm::StringMap<Entry> phases, passes; };` and
  `std::vector<std::unique_ptr<Shard>> shards_` owned by the `LoweringStats` (so a shard outlives
  its thread — EcoSplit workers exit before the banner prints).
- `Shard &localShard()`: a `thread_local` pair `{const LoweringStats *owner; uint64_t gen; Shard *s}`;
  on a miss (first call on this thread, or a different stats object), lock `mu_`, allocate a shard,
  push it into `shards_`, cache it. Each `LoweringStats` gets a unique `gen_` from a global atomic
  counter so a reused address never aliases a dead object's shard.
- `record`/`recordPass`: `auto &e = localShard().phases[name]; e.total += d; ++e.count;` — no lock.
- `print`: lock `mu_`, merge all shards into two temporary `StringMap`s by summing `total` and
  `count`, then print exactly as today. Sum is commutative and associative, so the merge order
  (shard creation order) cannot change a number; the printed table is already sorted by total.
- Requirement: `print` runs after all recording threads have finished (true today: the banner prints
  at exit, after the EcoSplit join and the pipeline).

**Expected:** the 0.18 s adaptor stretch becomes ~0.03 s; the banner shows
`EcoFoldProjectPass  <wall>  1 call`.

### P2. One chunked parallel helper (`P/EcoParallel.h`, new)

**Why.** `mlir::parallelForEach` and `mlir::parallelFor` create a `ParallelDiagnosticHandler` and call
`setOrderIDForThread`/`eraseOrderIDForThread` (a mutex each) **per element**. Called on ~75k
functions this serializes the threads.

```cpp
// Run fn(lo, hi) over [0, n) in at most 8 x threads contiguous chunks
// (dynamic hand-out); serial fn(0, n) when threading is off or n is small.
template <typename Fn>
void eco::forEachChunk(mlir::MLIRContext *ctx, size_t n, Fn &&fn,
                       size_t minPerChunk = 16);
```
- `nChunks = min(ceil(n / minPerChunk), 8 * ctx->getNumThreads())`; `nChunks <= 1` or
  `!ctx->isMultithreadingEnabled()` ⇒ call `fn(0, n)` directly.
- Otherwise `mlir::parallelFor(ctx, 0, nChunks, [&](size_t c){ fn(n*c/nChunks, n*(c+1)/nChunks); })`.
  Diagnostics stay ordered (by chunk, then sequentially inside it — the same total order).

**Call sites to convert** (each keeps its body; only the iteration changes):
- `P/EcoSymbolGraph.cpp:111` (edge collection per node);
- `P/EcoCapHoistPlan.cpp:218` (Phase A per defined function);
- `P/EcoGcFreePropagation.cpp:203` (per defined function);
- `P/EcoReachability.cpp:139` (drop dead bodies);
- `P/EcoGCPrepare.cpp:289` (per function);
- `EcoSplit.cpp:124` (op count per function).

Each site writes only to its own pre-sized slot (`lists[i]`, `cn[defIdx]`, …), so chunking is safe
exactly as the per-element form was. The existing hand-written chunk loops (Tail, ControlFlowToSCF,
E2L stage 2/strip) already chunk and stay as they are.

### P3. Symbol references without `getAttrDictionary`

**Why.** `Operation::getAttrDictionary()` on an op with properties builds a `NamedAttrList` from the
inherent attributes and uniques it as a `DictionaryAttr` (exclusive uniquer lock on a miss). It is
called once per op by `symgraph::collect` (Reachability, CapHoistPlan, EcoSplit build,
`addressTakenByName`), by E2L's strip (`getAttrDictionary` + `SymbolTable::getSymbolUses`), and by
ListTemplate's use index (`getSymbolUses`).

**New API — `P/EcoSymbolGraph.h`:**
```cpp
/// Call fn(SymbolRefAttr ref, bool isCallee) for every symbol reference held
/// in op's OWN attributes (inherent and discardable). Equivalent to walking
/// op->getAttrDictionary() for SymbolRefAttrs, without uniquing a dictionary.
void forEachSymbolRef(mlir::Operation *op,
                      llvm::function_ref<void(mlir::SymbolRefAttr, bool)> fn);
```
Implementation:
- `LLVM::CallOp`: if `getCalleeAttr()` ⇒ `fn(callee, true)`; then the generic path below for its
  *other* attributes, skipping the name `callee`.
- Generic: if `op->getPropertiesStorage()` (registered op with properties) then
  `NamedAttrList l; op->getName().populateInherentAttrs(op, l);` and visit `l`; then visit
  `op->getDiscardableAttrs()`. Otherwise visit `op->getAttrs()` (the raw dictionary, no allocation).
- Visiting one attribute value: skip leaf kinds that cannot contain a symbol reference —
  `IntegerAttr, FloatAttr, StringAttr, TypeAttr, UnitAttr, BoolAttr, DenseArrayAttr,
  DenseIntOrFPElementsAttr` (and `LLVM::LinkageAttr`, `LLVM::CConvAttr`, `LLVM::FastmathFlagsAttr`);
  a `SymbolRefAttr` is reported directly; anything else is walked with
  `Attribute::walk([&](SymbolRefAttr r){...})` (today's semantics).
- `isCallee` is `true` only for the call's `callee` attribute (today: `isCall && name == "callee"`).

**Users:**
1. `symgraph::collect`: replace the `getAttrDictionary()` loop with
   `forEachSymbolRef(op, [&](SymbolRefAttr r, bool callee){ add(r.getRootReference(), callee ? Call : Address); })`.
   The AddressOf arm is unchanged.
2. E2L strip (stage 5): replace the per-top-level-op `getAttrDictionary().walk` +
   `getSymbolUses(op)` with `op->walk([&](Operation *o){ forEachSymbolRef(o, mark); })`, where
   `mark` only records references to the **external-declaration candidates**: before the parallel
   region, collect the external `llvm.func`s into `DenseMap<StringAttr, unsigned> cand` (a few
   hundred); each chunk owns a `BitVector(cand.size())`; the merge ORs them. `unknownUses` and the
   `SymbolUserMap` fallback go away: the walk sees every op, including nested symbol tables (the
   module is the only one), which `getSymbolUses` would have refused. Erase order unchanged
   (`module.getOps<LLVMFuncOp>()` order).
3. ListTemplate use index: see P9.

**Validation twin:** `ECO_SYMREF_VALIDATE=1` makes `symgraph::build` also run the old
dictionary-based collector and abort with the op's name on any difference in the edge list. Run it
once at the end (§6) on the self-compile and the E2E corpus.

**Interaction to watch:** partition translation (`legalizeDIExpressionsRecursively`, upstream) also
calls `getAttrDictionary` on every op; today some of those dictionaries were pre-created by
`symgraph::build` in the EcoSplit build. Judge P3 on wall and on "partition translate (sum over
workers)", not on the pipeline alone.

### P4. TailConversions: listener-free SCF→CF

**Why.** Step 1 of each function is `applyPartialConversion(f, scfTarget, scfFrozen)`. The
`ConversionPatternRewriter` always has a listener, so `RewriterBase::splitBlock` moves every op after
the split point one at a time and records a `MoveOperationRewrite` for each. The `scf.if` lowering
splits at every `scf.if`, in program order, so a block with k `scf.if`s and n ops costs O(k·n)
recorded moves. String-literal and CAF diamonds (`EcoToLLVMGlobals.cpp` `rewrite*CallSitesFast`) put
~1,000 `scf.if`s into single blocks of `KernelSetFacts.facts` (34k ops) and the `toReport` functions:
the 1.4 s single-thread tail.

**Change — `P/EcoTailConversions.cpp`, step 1 only:**
- Replace `applyPartialConversion(f, scfTarget, scfFrozen)` with `lowerScfToCf(f, applicator)`:
  1. Collect the function's SCF ops in **pre-order** (`f->walk<WalkOrder::PreOrder>`), filtering
     `scf::IfOp, ForOp, WhileOp, IndexSwitchOp, ExecuteRegionOp, ParallelOp, ForallOp` — the same
     set the conversion target marks illegal, in the same order the conversion driver legalizes them.
  2. `PatternRewriter rewriter(ctx)` — no listener, so `splitBlock` is `Block::splitBlock` (one
     ilist splice) and `inlineRegionBefore` is a block-list splice.
  3. For each collected op: `rewriter.setInsertionPoint(op)`;
     `applicator.matchAndRewrite(op, rewriter)`; failure ⇒ pass failure. Outer ops come first; their
     lowering only *moves* nested regions (inline), so the inner op pointers stay valid.
  4. After the loop assert (debug) that no op of the illegal set remains in `f`, which catches a
     pattern that creates new SCF ops (`ParallelOp`/`ForallOp` lowerings do; eco never emits them —
     if one appears, fall back to `applyPartialConversion` for that function).
- `applicator` is per chunk: `PatternApplicator applicator(scfFrozen);
  applicator.applyDefaultCostModel();` (the conversion driver uses the same default benefit order).
- Step 2 (arith + cf → llvm conversion) and the cast reconciliation are unchanged.

**Why the output is identical.** The conversion driver legalizes the illegal ops in pre-order and
applies the same patterns; each SCF→CF pattern is a plain `OpRewritePattern` with no rollback. Block
creation order follows from the split/inline sequence, which is the same. The md5 gate decides.

**Secondary (only if the straggler still sets the stage) — BUILT as P4r.** After P4 the straggler
was still 0.4 s, 89 % in `ilist_traits<Operation>::transferNodesFromList`. A listener-free
`splitBlock` is one splice, but the splice still re-parents every op that moves, so the cost was
still O(k·n). P4r collects the ops **parents before children, but siblings in one block
last-first** (`collectScfOps`). Each lowering is local: split the op's block at the op, then inline
its regions before the continuation. So the final block layout does not depend on sibling order,
but each split now moves only the ops up to the next sibling, which has already been lowered.
Full reverse pre-order (children first) is NOT allowed: some parent patterns `cast<scf::YieldOp>`
the front block's terminator, and that assertion fired.

### P5. ListCursor: parallel loop collection

**Why.** `m.walk([&](scf::WhileOp w){ loops.push_back(w); })` visits ~4.2M ops serially (0.36 s);
analyze + rewrite are 0.04 s (the LC step parallelized only those and was FLAT).

**Change — `P/EcoListCursor.cpp` `runOnOperation`:**
- `SmallVector<Operation *> tops` of the top-level `LLVM::LLVMFuncOp`s with bodies, in module order;
  `std::vector<SmallVector<scf::WhileOp, 0>> per(tops.size())`;
  `eco::forEachChunk(ctx, tops.size(), …)` fills `per[i]` with `tops[i]->walk(...)` (same post-order
  walk as today).
- Concatenate `per` in order into `loops` (identical to today's list: `m.walk` visits top-level ops in
  order and only functions contain `scf.while`); the serial analyze/rewrite loop is unchanged, so the
  decls are still created by the first rewrite at module end.

### P6. E2L epilogue (stage 4) in parallel chunks

**Why.** The epilogue loop (`E2L` "Single post-conversion walk") does, per function: set the GC
strategy, install a CAF memo guard, the CAF and string-literal call-site diamonds, and the
shadow-root frame. All of it is function-local except:
1. `installCafMemoGuard` declares `eco_caf_promote` at module END on first use
   (`EcoToLLVMGlobals.cpp:598`).
2. The shadow-root helpers call `runtime.getOrCreate*` (cache hits in practice, but a miss would
   insert at module start).

**Change — `E2L` stage 4:**
- After `materializeStringLiteralSlots`, compute `needPromote` = exists a non-external function with
  `cafMemoFuncs.contains(name) && !shadowRootFuncs.contains(name)`. If `needPromote` and
  `!module.lookupSymbol<LLVMFuncOp>("eco_caf_promote")`, create the decl exactly as
  `installCafMemoGuard` does (factor its creation into `declareCafPromote(ModuleOp, Location)`,
  same location `func.getLoc()` of the FIRST such function, same `passthrough`). It lands at module
  end, after the string-literal slots and fill decls — the same position the first guard puts it
  today, because nothing else appends between those two points.
- Collect the non-external `llvm.func`s in module order; run with `eco::forEachChunk`:
  `setGarbageCollector`, `installCafMemoGuard(func, /*promoteDeclared=*/true)` (local `bool` set to
  true so it never touches the module), `rewriteCafCallSitesFast`, `rewriteStringLiteralCallSitesFast`.
  Failure ⇒ an atomic flag ⇒ `signalPassFailure()` after the region (today a failure only skips
  that function's lambda and keeps going, then fails the pass — same final result).
- Shadow-root work runs **serially after** the parallel region, in module order, for the functions in
  `shadowRootFuncs` (in practice `main` only). It touches only that function's body; any decl it
  might create goes to module start, independent of the module-end decl above.
- Keep `runtime.frozen = false` (unchanged), since the shadow-root step may create.

### P7. E2L pre-materialization: one parallel demand collection (+ stage 1 walk)

**Why.** Stage 2b walks every body four times serially (`preMaterializeStringLiterals`,
`preMaterializeStringCases`, and both walks of `preMaterializeClosureArtifacts`); the profile shows
~⅓ of the stage is walking.

**Change:**
- New struct in `P/EcoToLLVMInternal.h`:
  ```cpp
  struct PreMatDemand {           // per body function, in walk (post-)order
      SmallVector<Operation *, 0> literals;  // eco.string_literal, non-empty value
      SmallVector<Operation *, 0> cases;     // eco.case ops preMaterializeStringCases selects
      SmallVector<Operation *, 0> closure;   // PapExtend, CallOp(indirect), PapCreate,
                                             // PapCreateGroup, AllocateClosure, MakeClosure
  };
  ```
- `collectPreMatDemand(ArrayRef<LLVMFuncOp> funcs, std::vector<PreMatDemand> &out, MLIRContext*)`:
  `eco::forEachChunk` over `funcs`; each function does ONE `func.walk([&](Operation *op){...})`
  (default post-order, the order all four walks use today) and appends to the three lists using
  exactly the predicates the four walks use (the string-case predicate is factored out of
  `preMaterializeStringCases` into `isPreMatStringCase(Operation*)`).
- The three pre-materialization functions take `ArrayRef<PreMatDemand>` instead of the function list
  and iterate `for (d : demand) for (op : d.literals) …` — the body of each walk lambda is moved
  verbatim into the loop. Walk 1 and walk 2 of the closure function both iterate `d.closure`
  (each lambda already ignores the op kinds it does not handle).
- Counters, side maps, creation order and insertion points are unchanged ⇒ identical output.
- Stage 1: `module.walk([&](func::FuncOp …))` becomes `module.getOps<func::FuncOp>()` (`func.func` is
  only top-level).

### P8. E2L stage 0 sharded into scratch modules

**Why.** Stage 0 converts ~75k `func.func` shells, but the conversion driver collects and
legality-checks every op of every body (~4.2M), serially.

**Change — `E2L` stage 0 becomes three phases:**
1. **Serial, in place**: `applyFullConversion(ArrayRef<Operation*> serialOps, sigTarget, patterns)`
   where `serialOps` = every top-level `func.func` with `is_kernel` (the only pattern that reads or
   writes `runtime.symCache`), every `eco.global` and every `eco.type_table` (module-level patterns that
   insert at module start / use `lookupSymbol`), in module order — the same relative order today's
   single conversion processes them in.
2. **Parallel, sharded**: split the module body into K = min(8 × threads, #top-level ops / 64)
   contiguous ranges. For each range create a detached `ModuleOp scratch = ModuleOp::create(loc)`
   and splice the range into it (`scratch.getBody()->getOperations().splice(end, module ops, first,
   last)`), serially (the source ilist is shared). Then, in parallel per shard with its own
   `EcoTypeConverter`, `ConversionTarget` (same legality as today) and frozen pattern set (same
   `populate*` calls): `applyFullConversion(scratch, …)`. Only non-kernel `func.func`s are illegal
   by now; they are replaced in place inside their shard.
3. **Serial**: splice every shard's ops back, in shard order, at the original position (the range is
   remembered as "insert before the op that followed it", or the end); destroy the empty scratch
   modules.
- Then `runtime.symCache.clear()` as today.

**Safety argument.** The shell patterns (`FuncOpConversion`, `SretFuncOpLowering`) create the new
`llvm.func` before the old op and erase the old one; neither reads the symbol table or the parent
module (`useBarePtrCallConv`, no C-interface wrappers), and the kernel pattern — the one that does —
never fires in a shard (no `is_kernel` op is left). `EcoTypeConverter` is per shard (it has mutable
caches). Context uniquing is thread-safe. If the md5 gate fails, compare the dumps: the most likely
culprit is a pattern looking at the parent module (e.g. a data-layout query on the scratch module);
fix by copying the module's attributes onto the scratch module.
- Serial fallback (`!isMultithreadingEnabled()` or `ECO_ECO2LLVM_PARALLEL=0`): today's single
  `applyFullConversion(module)`.

### P9. ListTemplate: parallel pre-scan and use index

**Change — `P/EcoListTemplate.cpp` `runOnOperation`:**
- Pre-scan (parallel, `eco::forEachChunk` over the top-level `func.func`s with bodies): per function,
  `hasListMap`, `hasWhile` flags, from one walk.
- `expandListMaps`: walk only flagged functions (serially, in module order, same walk) instead of
  `m.walk` — the list of `ListMapOp`s is identical.
- The while rewriter: replace `m.walk([&](scf::WhileOp w){…})` by a loop over module-order top-level
  `func.func`s with `hasWhile`, each doing today's `f.walk` (same post-order within the function).
  Functions created mid-loop by `ensureDecl` are declarations (no whiles) — the same set the module
  walk would visit.
- The phase-2 use index (`useIndex`, built on the first candidate): build it from a parallel
  `forEachSymbolRef` collection over the top-level ops (each chunk: `vector<pair<StringAttr,
  Operation*>>` in walk order; concatenate in chunk order), instead of
  `SymbolTable::getSymbolUses(&m.getBodyRegion())`. Only the per-symbol user list matters (users are
  checked individually and outer call sites are wrapped locally), so the order within a symbol's
  list does not affect output. `useIndexFailed` can no longer be set (keep the flag; it stays false).

### P10. BFToLLVM: convert only the bf functions

**Change — `P/BFToLLVM.cpp`:** replace the early-out walk with a parallel per-top-level-op scan that
returns the ops containing a bf op (module order). Empty ⇒ return (as today). Otherwise create the
runtime decls (unchanged) and `applyPartialConversion(ArrayRef<Operation*>(bfTops), target,
patterns)`. The conversion of the other functions was a no-op (every op legal), so the result is
identical.

## 5. Out of scope (recorded so they are not lost)

- **Allocator.** Cross-thread frees into the main arena are a real lock (tcache experiment above).
  A scalable allocator (mimalloc/jemalloc) is not installed in this container; it belongs with the
  A2 image rebuild. The tcache tunable costs +2.1 GB RSS and is not shipped.
- **Sharded bytecode parse** needs a front-end change (multiple bytecode shards or a function-offset
  index); 0.7 s.
- **One symbol graph for Reachability + CapHoistPlan + GcFree + EcoSplit.** Decide after P2/P3 are
  measured: if each `symgraph::build` still costs > 50 ms, fuse.
- **Partition translate uniquer contention** in upstream `legalizeDIExpressionsRecursively` needs an
  MLIR change.
- ~~**Parallel artifact construction** in pre-materialization~~ — BUILT as P11 (below).

## 6. Gates (batched, end of series, `ulimit -c 0`, strictly serial)

1. **Byte identity** of the final tree: executable md5 = `60fb7e14f3c7485d47c6b035094530bc` and the
   `ECO_DUMP_LOWERED_MLIR` dump md5 = `6d0f526ed4d46007d3838d61fcbc55a4`.
2. **Serial paths:** the same two md5s with `--mlir-disable-threading` (every new parallel region has
   a serial fallback) and with `ECO_ECO2LLVM_PARALLEL=0`.
3. **Symbol-ref twin:** `ECO_SYMREF_VALIDATE=1` on the self-compile (no abort).
4. **E2E:** `cmake --build build --target check` (C++-only change), run once, tee'd. Expected: the
   known baseline (all pass; AOT 900/902 if run).
5. **Unit tests:** rebuild `test`, run `build/test/test` once.
6. A bootstrap fixed point is implied by gate 1 (the lowered compiler is byte-identical to the
   reference's, which is at its fixed point).

## 7. Risks

- **P8** is the riskiest (an upstream pattern might consult the parent module); the md5 gate catches
  it, and the step can be dropped without affecting the others.
- **P4** relies on the SCF→CF patterns never needing rollback and never creating new SCF ops for the
  op kinds eco emits; guarded by the post-loop assertion and fallback.
- **P3** changes how symbol references are found; the validate twin compares it with the old
  collector op by op.
- Parallel regions that write module-level state would race. Every step above keeps module-level
  creation in a serial section, and the md5 gate (which compares a deterministic run) plus the
  `--mlir-disable-threading` gate check it.

## Implementation results (2026-10-03)

One lowering run per step, as in `benchmarks/backend-opt-loop.md` (input `p04/base.mlir`; logs
`stats-backend-opt/P07-<id>.{stats,time}`). **Every step's executable is byte-identical to the
reference** (md5 `60fb7e14…`).

| step | wall (s) | user (s) | max RSS (kB) | MLIR pipeline (s) | step's target | verdict |
|---|---|---|---|---|---|---|
| base (ref-P07) | 25.10 | 360.00 | 7,686,016 | 8.02 | — | reference |
| P1 FoldProject module pass + per-thread stats | 25.02 | 361.56 | 7,679,524 | 7.91 | adaptor 0.18 s → FoldProject 5 ms | kept (deletes a lock) |
| P2 chunked parallel helper | 24.47 | 357.37 | 7,682,440 | 7.38 | CapHoist 0.55→0.32, Reach 0.52→0.24, GcFree 0.21→0.07, EcoSplit build 0.75→0.54 s | WIN |
| P3 symbol refs without dictionaries | 23.76 | 349.63 | 7,604,400 | 6.55 | E2L stage 5 0.62→0.07, EcoSplit build 0.54→0.33 s | WIN (see note) |
| P4 listener-free SCF→CF (+ fold-first) | 22.41 | 345.84 | 6,679,020 | 5.08 | Tail 2.11→0.65 s, RSS −0.9 GB | WIN |
| P5 ListCursor parallel collection | 21.84 | 346.60 | 6,677,840 | 4.80 | ListCursor 0.39→0.12 s | WIN |
| P6 parallel E2L epilogue | 21.56 | 346.69 | 6,720,276 | 4.44 | stage 4 0.47→0.15 s | WIN (amendment-1) |
| P7 one parallel pre-mat collection | 21.26 | 347.60 | 6,711,400 | 4.24 | stage 2b 0.76→0.51, stage 1 0.07→0.03 s | WIN (amendment-1) |
| P8 sharded stage 0 | 20.79 | 346.91 | 6,674,504 | 3.58 | stage 0 0.74→0.15 s | WIN |
| P9 ListTemplate pre-scan + parallel index | 20.37 | 347.17 | 6,675,448 | 3.22 | ListTemplate 0.40→0.08 s | WIN (amendment-1) |
| P10 BFToLLVM bf functions only | 20.12 | 347.83 | 6,681,856 | 3.04 | BFToLLVM 0.12→0.02 s | WIN (amendment-1) |
| P4r siblings last-first | 20.04 | 345.74 | 6,681,892 | 2.74 | Tail 0.60→0.29 s | WIN (amendment-1) |

**Total:** pipeline 8.02 → 2.74 s (−66 %), wall 25.10 → 20.04 s (−5.06 s), max RSS −1.0 GB.

**Profile after** (`stats-backend-opt/prof/p07final.*`):
- average pipeline parallelism went from 6.1× to 8.5×;
- the spinlock share of pipeline CPU fell from 33 % to 13 %.

**Notes:**
- **Two equivalence traps found by the md5 gate.**
  - P4 first missed the conversion driver's **fold-first** legalization.
    `DialectConversionFoldingMode::BeforePatterns` folds an illegal op before it applies patterns,
    and `scf.if`'s folder rewrites `if (xor c, true)` into `if c` with the regions swapped. The
    driver now folds in place first, and falls back to the conversion driver on a replacing fold.
  - P4r's first form, full reverse pre-order, hit an assertion; see §4 P4.
- **P3 moved part of the uniquer contention into the workers.**
  - Partition translate's CPU sum went 22.9 → 31.5 s. Upstream `legalizeDIExpressionsRecursively`
    calls `getAttrDictionary` on every op, and those dictionaries are no longer pre-created by
    `symgraph::build` on the source module.
  - The drain rose 0.3 s; the net wall change was still −0.71 s.
  - Removing that cost needs an MLIR change (§5).
- **P1 banner:** FoldProject now reports its wall (5 ms, 1 call). It used to report the CPU sum of
  56,944 per-function runs (1.12 s).

**Gates (§6), run on the final tree `keep-P4r`:**
1. Byte identity: executable md5 `60fb7e14f3c7485d47c6b035094530bc` and lowered-MLIR md5
   `6d0f526ed4d46007d3838d61fcbc55a4`, both equal to the reference.
2. Serial paths: `--mlir-disable-threading` and `ECO_ECO2LLVM_PARALLEL=0` both give the identical
   lowered MLIR.
   - The no-threading *executable* differs from the threaded one by design: EcoSplit requires
     multithreading (`mlirSplitPartitionCount` returns 1), so that path uses the old backend split.
3. `ECO_SYMREF_VALIDATE=1` on the self-compile: no mismatch, and the executable is identical.
4. E2E `check` and unit tests: see below.
4. E2E `cmake --build build --target check`: **PASSED**, 2028 passed and 0 failed (`/tmp/test_output.txt`).
5. Unit tests `build/test/test` (rebuilt): **PASSED**, 2028 passed and 0 failed.

## P11: parallel artifact construction, insertion in order (2026-10-03, after the CPU timeline)

After P7, stage 2b was the largest serial block, at 0.51 s:
- string literals 50 ms;
- closure artifacts (wrappers, `$sat` entries, descriptors, eval layouts) 447 ms.

A DWARF profile showed the closure part is IR *construction*: `OpBuilder::create` 23 %, the
creation-time `DictionaryAttr` uniquing 16 %, `StringAttr` for new names 14 %. Lookups and
decisions were about a third.

**Mechanism** (`EcoToLLVMInternal.h`: `EcoRuntime::topLog`, `pendingSymbols`, `emitTopLevel`,
`placeTopLevel`, `deferredBodies`, `deferOrBuild`):

1. **Plan (serial, program order).** Every creator keeps its decisions, counters, names and
   dedup. Where it used to insert an op at module start, it appends an entry to the ordered log
   instead: a builder that makes the op *detached*, body included.
   - Logged-but-unbuilt cached names go into `pendingSymbols`, so the creators' dedup checks
     (`isPending`) still see them.
   - The rare extern decls for targets are made eagerly (`placeTopLevel`), so later lookups see a
     real op; their insertion is still logged in order.
   - `getOrCreateWrapper` reports the wrapper's name (`outName`), and `getOrCreateEvalDesc` takes
     a name, so the plan never needs an unbuilt op.
   - The `$sat` capture-ABI check moved ahead of creation; it used to `erase` a half-built entry.
2. **Build (parallel).** One `forEachChunk` builds every logged op, plus the deferred
   string-literal initializers. The symbol cache is frozen meanwhile: the jobs only read it.
3. **Insert (serial).** The ops are `push_front()`ed in log order, which is exactly where
   "insert at module start, in creation order" put them, then cached where the eager creator
   cached them.

Also added: exact memos for repeated `(target, arity, result kind)` and repeated bare-function
descriptors, and `evalLayoutNames` keyed by string instead of `StringAttr`. Neither saves
measurable time.

`ECO_PREMAT_PARALLEL=0` runs the creators eagerly, as before.

| | serial plan | parallel build + insert | stage 2b total | pipeline | wall |
|---|---|---|---|---|---|
| before (P4r) | — | — | 0.51 s | 2.74 s | 20.04 s |
| P11 | 0.14 s | 0.11 s | 0.32 s | 2.52 s | 19.69 s |

**The parallel build is contention-bound.**
- It uses 1.44 CPU-seconds at about 10× parallelism, where the serial build took about 0.3 s.
- Each new artifact uniques a new symbol name and a new attribute dictionary inside MLIR's
  `Operation::create`, and those take the context's exclusive uniquer lock.
- Fewer tasks did not help: 4, 8 and 12 tasks gave 173, 108 and 101 ms.
- A further gain would need ops built through properties, avoiding the creation dictionary, or an
  MLIR change.

**Gates:**
- **Byte identity:** the executable matches the reference md5 `60fb7e14…` (measured run and a
  rerun). The lowered MLIR matches `6d0f526e…` in the default, `ECO_PREMAT_PARALLEL=0` and
  `--mlir-disable-threading` runs.
- **E2E `check` and unit tests:** see below.
- E2E `check`: **PASSED**, 2028 passed and 0 failed. Unit tests (`build/test/test`, rebuilt): **PASSED**, 2028 passed and 0 failed.
