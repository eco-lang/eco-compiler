# Backend lowering optimization plan

**Goal:** make `eco-boot-native <compiler>.mlir -o <exe>` (the backend lowering of the
self-hosted compiler) run much faster while the generated program stays correct.

**Loop:** `benchmarks/backend-opt-loop.md`. Each step is one lowering run, judged on wall time
against the best row so far. Correctness gates are batched at the end of the series.

**Status (2026-10-01): series run. 209.93 s → 44.09 s wall (−79 %).** The final tree is
`keep-B4`. All batched gates pass:
- bootstrap fixed point, 4/4 self-compiles;
- recursive tax +0.56 % against a 3 % gate;
- unit + JIT E2E 2006/2006;
- IR determinism.

AOT E2E was not run (see the loop doc). Per-step results are in `benchmarks/backend-opt-loop.md`
§7/§8.

| step | outcome |
|---|---|
| A1 cgu default | WIN −141.2 s |
| A1b no attrs pair | WIN −2.7 s |
| A1c no prologue GlobalOpt | WIN −2.8 s |
| A1d IPSCCP without funcspec | WIN −1.1 s |
| A3 own `-O2` pipeline | FLAT, kept, −26 s CPU |
| B1 O(1) asserts | WIN −3.8 s |
| B3b parallel decl strip | WIN −3.3 s |
| B2 chunked tail conversions | WIN (phase rule) |
| RC per-function reconcile | FLAT, kept |
| C2′ LPT partitions | WIN −2.1 s |
| C3 no worker `verifyModule` | WIN (phase rule) |
| B5 parallel EcoControlFlowToSCF | WIN −1.9 s |
| M1 malloc tuning | marginal WIN, +0.87 GB RSS |
| X1 skip teardown | WIN −2.1 s |
| B6 parallel GCPrepare | WIN −1.3 s |
| B8a getOps | FLAT, kept |
| B7 per-site lookups | FLAT, kept |
| B4 finer chunks | FLAT, kept |
| D1 prologue timers | instrumentation |

Reverted:
- C2 under the old 2 s floor; it was re-tried as C2′.
- S1 bitcode without irsymtab.
- T1 location strip.
- LC parallel ListCursor.
- CH parallel cap-hoist (+1.2 GB RSS).

**Open:**
- **A2:** the no-assert LLVM images. Manual, the user's step on 2026-10-02.
- **A4:** not needed, because the gate passed.
- **B9, B10 and C4:** each under 0.5 s.
- **C1:** IR volume. `$cap` variants are 20 % of the IR.
- **Upstream MLIR:** `legalizeDIExpressionsRecursively` costs about 2.5 s of translation.
- **Tail-pass scaling:** 1.9 s wall for about 10 s of CPU.

The base snapshot is `be-base`.

## 0. Where the time goes (base tree, 2026-10-01)

Input is `ecoGCR.mlir`: about 98k functions, 13.2 MB of bytecode. The base row is **215.8 s
wall**, 433 s user CPU and 6.8 GB max RSS. That row is provisional: it was measured while
investigation agents were running, and it gets re-measured idle before step 1. Times below are
wall unless marked Σ (summed over threads).

| phase | time | serial? |
|---|---|---|
| MLIR parse + verify | 0.76 s | serial |
| MLIR lowering pipeline | 18.9 s | mostly serial (see §0.2) |
| MLIR → LLVM IR translation | 6.8 s | serial |
| Internalize + GlobalDCE, capacity hoist, `$cap` prepass, gc-free leaf propagation | 2.3 s | serial |
| RS4GC + frame pointers | 8.8 s | serial |
| **whole-module `-O2` opt** | **155.9 s** | **serial (one core)** |
| externalize + serialize once | 5.9 s | serial |
| lazy extract | 17.5 s Σ | 24 workers |
| partition emit | 144.3 s Σ | 24 workers |
| parallel opt+emit drain (the part of emit on the critical path) | 8.7 s | |
| link (clang++) | 1.9 s | serial |

**The lowering is about 80 % serial LLVM opt.** The rest is mostly serial MLIR work and
translation.

### 0.1 Whole-module opt, by pass (`perf` call stacks, 3,774 main-thread samples)

`makeOptimizingTransformer` builds its `PassBuilder` with no pass instrumentation, so
`--time-passes` cannot see this stage. It also crashes with an LLVM `Timer` assertion under
parallel emit. These shares come from the innermost `PassModel<…, PassName>` frame on each
sampled stack.

| innermost pass | share | ≈ s |
|---|---|---|
| InstCombine | 23.4 % | 36 |
| SLPVectorizer | 11.0 % | 17 |
| GVN | 6.8 % | 11 |
| CGSCC adaptor | 5.1 % | 8 |
| IPSCCP | 5.1 % | 8 |
| SimplifyCFG | 5.0 % | 8 |
| EarlyCSE | 4.3 % | 7 |
| CorrelatedValuePropagation | 4.0 % | 6 |
| CalledValuePropagation | 3.2 % | 5 |
| GlobalOpt | 2.6 % | 4 |
| JumpThreading 2.5, DSE 2.0, Reassociate 1.6, SCCP 1.5, … | | |

By outermost pass, the inliner wrapper is 53.7 % and the post-inline function passes are 31.6 %.
Actual inlining work is only about 2 %: RS4GC runs before opt, so every call to a generated
function is already a `gc.statepoint` the inliner cannot touch. The cost is the fused
simplification pipeline, and it scales with how much IR there is.

**Why opt tripled since July (51 s → 151 s).** No setting changed: still `-O2`, the same
tuning options, the same June LLVM build. The IR grew.

| | Aug 9 | now |
|---|---|---|
| `.text` | 22.3 MB | 31.1 MB |
| functions with statepoints | 42.5k | 64.9k |

Growth came from inline-deref diamonds (Jul 22), inline nursery allocation (38.6k diamonds),
CAF memoization, chunked lists, `$cap` variants (21 % of text), 25k `__closure_sat_*` thunks
and 16k typed closure wrappers. The lowering was 82 s on Jul 7, 77–90 s on Jul 22, about 4m15s
by Aug 8–9, and 165–208 s in mid-September. The September figures also include the MLIR-side
`lookupSymbol` blow-ups fixed today (pre-loop rows in the loop doc).

### 0.2 MLIR pipeline (18.9 s)

`LoweringStats` sums nested pass times across threads. So `SCFToControlFlow` 5.83 s plus
`ArithToLLVM` 3.22 s is CPU time; their wall time is about 2.2–2.5 s (the `OpToOpPassAdaptor`
line). The serial heavyweights are:
- `EcoToLLVMPass`: 11.0 s, against 4.7 s in July. Only its Stage 2 runs in parallel.
- `EcoControlFlowToSCF`: 1.7 s.
- `ConvertControlFlowToLLVM`: 1.3 s.
- `EcoGCPrepare`: 0.7 s.

### 0.3 Emit workers (4,240 samples, threads named `eco-boot-native`, not `llvm-worker-*`)

The `llvm-worker-N` threads are MLIR's thread pool, i.e. parallel `EcoToLLVM`. The emit workers
are `std::thread`s that inherit the process name.

| emit work | share |
|---|---|
| SelectionDAG ISel | 29 % |
| lazy extract (bitcode parse) | 20 % |
| other MachineFunction passes | 13.4 % |
| register allocation and liveness | 12.5 % |
| CodeGenPrepare and friends | 5.7 % |
| MachineScheduler | 4.7 % |
| legacy pass-manager overhead | 4.6 % |
| AsmPrinter/MC | 4.6 % |
| statepoint lowering and stackmap emission | 2.3 % |

- **Balance:** max/mean is 1.23 across workers.
- **Contention:** none in the emit workers. Kernel spinlocks (about 2.6 % of all samples) sit in
  the MLIR threads, probably mmap-lock contention from malloc during parallel `EcoToLLVM`.

### 0.4 Pass dependency map (MLIR pipeline, `runtime/src/codegen/EcoPipeline.cpp`)

R = a real dependency, I = an incidental ordering, VAL = validation builds only.

| # | pass (line) | anchor | parallel today | module-level writes | ordering |
|---|---|---|---|---|---|
| 1 | RCElimination :55 | module | no | none (check only) | I |
| 2 | CheckEcoClosureCaptures :61 (VAL) | module | no | none | R before 3 |
| 3 | EcoPAPSimplify :65 | module (seeded greedy) | no | none; reads callee signatures | R before 4 |
| 4 | EcoCompareCaseRewrite :71 | module | no | `Elm_Kernel_Utils_cmp3` decl | R after 3, before 5 |
| 5 | UndefinedFunction :74 | module | no | external decls | R after 4 |
| 6 | JoinpointNormalization :104 | module | no | none (per function) | R before 7 |
| 7 | EcoControlFlowToSCF :105 | module (greedy, whole module) | no | `Elm_Kernel_Utils_equal` decl | R: produces the `scf` that 8, 15 and 18 need |
| 8 | EcoListTemplate :111 | module | no | kernel decls; rewrites call sites in other functions | R after 7, before 11 and 12 |
| 9 | EcoFoldProject :136 | func, nested | yes | none | R before 12; after 7 is I |
| 11 | EcoMarkGCLeafCalls :155 | module | no | none; reads sibling decl attributes | R after 4, 5, 7, 8 and before 12. Its position relative to 9 is I |
| 12 | EcoGCPrepare :156 | module (per-function work only) | no | none | R before 14 and 15 |
| 14 | BFToLLVM :162 | module | no | runtime decls | R before 15; after 12 is likely I |
| 15 | EcoToLLVM :163 | module, Stage 2 parallel | partly | decls, globals, wrappers, eval layouts; the epilogue adds `scf.if` | R |
| 16 | EcoListCursor :168 | module | no | `ensureFn` decls | R after 15, before 18 |
| 18 | SCFToControlFlow :183 | llvm.func, nested | yes (98,355 calls, declarations included) | none | R after 15 and 16 |
| 19 | ArithToLLVM :184 | llvm.func, nested | yes | none | R after 18 |
| 20 | ConvertControlFlowToLLVM :185 | module (stock, ModuleOp-pinned) | no | none | R after 18 |
| 21 | ReconcileUnrealizedCasts :186 | module | no | none | R last |

LLVM side (`EcoBackend.cpp` `runEcoBackend`):
- **`none` mode (default):** translate → internalize + GlobalDCE → capacity hoist → `$cap`
  inline prepass → gc-free leaf propagation → RS4GC + frame pointers → whole-module `-O2` →
  externalize + serialize → workers {lazy extract → emit} → link.
- **Parallel modes (`dev`/`cgu`):** RS4GC moves into the workers, and the cheap whole-module
  IPO prologue replaces the serial `-O2`.

**What is serial and why:** every MLIR pass that creates module-level declarations, plus every
pass that was simply written as a module walk. The only structural barriers are symbol creation
and cross-function call-site rewrites (EcoListTemplate, EcoPAPSimplify).

## 1. Steps, ordered by expected wall win

Every step is one loop iteration. "codegen-changing" means the generated code differs, so the
recursive-tax gate (loop §6.4) applies before the series closes. Estimated savings are against
the base tree. Estimates for later steps shrink once earlier steps land, because the serial path
changes.

### Step 0: re-measure the base, plus two diagnostic legs (no code change)

- **0a.** Re-run the base on an idle box and replace the provisional row.
- **0b. Untimed diagnostic leg 1:** `ECO_ECO2LLVM_STATS=1`, which gives the timings of
  `EcoToLLVM`'s internal stages (`EcoToLLVM.cpp:160-170`). This tells us which of B1–B4 to do
  first.
- **0c. Untimed diagnostic leg 2:** `--emit=llvm` IR instruction counts by function family
  (`$cap`, `__closure_sat_*`, `__closure_wrapper_typed_*`, specs, CAF guards, string-literal
  diamonds). This quantifies §0.1's growth claim for C1.

### A. Serial LLVM opt: about 80 % of the wall

**A1. Make `--parallel-opt=cgu` the default.** codegen-changing; estimated **−120 to −140 s**.
- **What it does:** RS4GC, full `-O2` and emit run per partition on 24 cores
  (`EcoBackend.cpp:3557-3566`, `optimizePartitionModule` :558). Only the cheap whole-module IPO
  prologue (IPSCCP, GlobalOpt, GlobalDCE; :495) stays serial. In July `cgu` gave backend
  65.8 → 31.4 s.
- **Code-quality risk:** only cross-partition inlining is lost, and only of gc-leaf callees.
  Inlining is about 2 % of opt today, because statepoints already block the rest. The `$cap`
  inline prepass stays whole-module.
- **Restore `PostOrderFunctionAttrs` in the cgu prologue** (dropped in July, :507-518). Without
  it, declarations from other partitions lose inferred `readnone`/`nounwind`, and that matters
  more once opt runs per partition. Cost is about 1–3 s serial.
- **Gate:** the 3 % recursive-tax check (loop §6.4), never run for `cgu`. If it fails, see A4.
- **Change the default in source** (`eco-boot.cpp:190`, and `EcoNativeOptions::parallelOpt` so
  `eco make` follows).
- **Invariants:** REP_LLVM_001(a). Per-partition RS4GC runs before per-partition opt, as in the
  existing guarded path. Never combine with `--rs4gc-after-opt`.

**A2. Rebuild the LLVM/MLIR images without assertions.** Generated code is identical;
estimated **−25 to −50 s** at today's serial opt, less after A1 but all of it in CPU.
- **MANUAL, the user's step:** this container cannot rebuild `/opt/llvm-mlir`. Planned for
  2026-10-02.
- `docker/llvm-debian.Dockerfile:30` and `docker/llvm-alpine.Dockerfile:67` set
  `-DLLVM_ENABLE_ASSERTIONS=ON`. The alpine image is behind the shipped static-musl release, so
  the shipped `eco make` backend runs assertion-enabled LLVM too.
- Assertion-only work shows in the profile (`LiveRange::verify` in the emit workers;
  `ABI_BREAKING_CHECKS`). Assertions typically cost 15–30 % of LLVM CPU.
- **Keep an assertions build available** for validation work: a second image tag or prefix, and
  a CMake preset that points at it. Eco code must be compiled against matching headers, because
  `LLVM_ENABLE_ABI_BREAKING_CHECKS` follows assertions.
- **Measure:** the loop's base command on the new image. Record it as step A2 against the then
  best row. Rebuild every target first.

**A3. Use our own `-O2` pipeline: SLP and loop vectorizers off, CalledValuePropagation
skipped.** codegen-changing (expected flat on runtime); estimated **−20 s serial** before A1, and
CPU-only after it.
- Replace `mlir::makeOptimizingTransformer` with a `PassBuilder` whose `PipelineTuningOptions`
  have `SLPVectorization=false` and `LoopVectorization=false`, at `EcoBackend.cpp:3586`, and at
  :561 for `cgu` partitions.
- **Why SLP is safe to drop:** in a 3 MB slice of generated code, 488 of 811,576 instructions
  touch xmm/ymm registers (0.06 %). SLP is 11 % of opt and buys essentially nothing.
- **CalledValuePropagation** (3.2 %) only attaches `!callees` metadata, and after RS4GC indirect
  calls are statepoints. Skip it via a `PassInstrumentationCallbacks` `shouldRun` filter, which
  also gives us the hook for pass timing (D1).
- Both items were proposed by the user (2026-10-01). Recursive-tax gate.

**A4. Fallback if A1 fails its gate: ThinLTO-style import.**
- Summaries, then a combined index, then importing hot or small callees as
  `available_externally` into each partition (July plan Phase 5,
  `plans/parallel-llvm-opt-partitioning.md`).
- Only build this if A1's recursive tax exceeds 3 %.

### B. MLIR pipeline (18.9 s → estimated 8–10 s)

**B1. Remove the linear module scans inside asserts in parallel Stage 2.** Code unchanged;
estimated **−1 to −4 s**.
- `EcoToLLVMClosures.cpp:2006`, `:2020` and `:2135` assert via `runtime.module.lookupSymbol`
  once per closure op (papCreate/group, makeClosure, allocateClosure, papExtend, indirect call).
- Asserts are live because `CMakePresets.json:35` sets `-UNDEBUG`. Descriptors, wrappers and
  layouts are inserted at module START, so the first-created and most-used ones end up deepest.
- **Fix:** keep the asserts but make them O(1). Use `runtime.lookupSymbol<LLVM::GlobalOp>`
  (descriptors are already in `symCache`) and `runtime.evalLayoutNames.contains(...)` for
  layouts.

**B2. Fold the tail conversions into `EcoToLLVM` Stage 2.** Estimated **−3 to −4 s**.
- Inside `convertChunk`, after each function's `applyFullConversion`, do the following per
  function:
  - run the list-cursor rewrite (its decls are created before `freeze()`);
  - run one `applyPartialConversion` with SCF→CF, `cf` ControlFlowToLLVM (eco emits no
    `cf.assert`, already audited) and Arith→LLVM;
  - reconcile that function's casts via `mlir::reconcileUnrealizedCasts(ArrayRef<…>)`.
- Keep a small module-level reconcile for anything outside functions.
- **What this removes:** passes 16, 18, 19, 20 and 21 as separate sweeps. Today they cost
  98,355 × 2 nested pass invocations, each rebuilding a converter, pattern set and target (about
  61 and 32 µs each, about 40 % of them on wrappers or declarations), plus 1.96 s of serial
  passes.
- **Risk:** this is the parked `EcoTailConversions` idea, which corrupted memory because of
  pattern-state lifetime across pass clones. The difference here is that state lives per chunk
  on the stack, the lifetime model Stage 2 already uses safely.
- **Gate (batched):** a sorted-hash identity check of `--emit=mlir-llvm` output plus the
  bootstrap fixed point.

**B3. Move `EcoToLLVM`'s serial epilogue into Stage 2, and replace the unused-decl strip.**
Estimated **−1.5 to −3 s**.
- **(a) Epilogue walk.** The serial walk (`EcoToLLVM.cpp:549-588`) does a recursive
  `module.walk` plus two more body walks per function: CAF call sites (`EcoToLLVMGlobals.cpp:689`)
  and string-literal call sites (:862).
  - Before `freeze()`, call `materializeStringLiteralSlots` and pre-declare `eco_caf_promote`.
    Both append at the module end, and Stage 2 adds no module ops, so final positions are
    unchanged.
  - Then run `setGarbageCollector`, `installCafMemoGuard`, `rewriteCafCallSitesFast` and
    `rewriteStringLiteralCallSitesFast` per function inside `convertChunk`. Fuse the two
    call-site walks into one.
  - Only main's shadow-root frame stays serial. Find main through `symCache`.
  - Invariant: CGEN_068 (the CAF guard).
- **(b) Unused-decl strip.** `SymbolUserMap` over the whole module (`EcoToLLVM.cpp:607-615`) is
  serial. It also builds and uniques an attribute dictionary for every LLVM op, which is millions
  of uniquer hits. Replace it:
  - each Stage 2 chunk collects a thread-local set of referenced callee and `AddressOf` names;
  - merge the sets, then scan the few module-level ops serially (global initializers,
    `__eco_init_globals`);
  - erase the external decls that are not in the merged set;
  - under `ECO_LOWERING_VALIDATION`, cross-check the result against `SymbolUserMap`.

  A missed reference kind would fail loudly at translation, not miscompile.

**B4. Stage 2 load balancing, and a parallel pre-materialization collect.** Estimated
**−1 to −2 s**.
- **Load balancing:** Stage 2 uses 24 equal-COUNT contiguous chunks (`EcoToLLVM.cpp:478-499`).
  Use T workers that build patterns and a converter once, then pull batches of 16–64 functions
  from an atomic index. Output is independent of order, because nothing mutates the module
  after `freeze()`.
- **Pre-materialization:** it does four serial full body walks (`EcoToLLVMTypes.cpp:187`,
  `EcoToLLVMControlFlow.cpp:1193`, `EcoToLLVMClosures.cpp:3138` and :3218).
  - Replace them with ONE parallel collect into per-function op lists, then the existing serial
    create loops over those lists in function order. That keeps creation order identical.
  - Memoize `materialize()` (:3194) on (symbol, arity, result kind).
  - The pre-scan at `EcoToLLVM.cpp:210` becomes `getOps<func::FuncOp>()`.

**B5. Give `EcoControlFlowToSCF` a seeded driver.** May change MLIR output; estimated
**−1.2 s**.
- Today `applyPatternsGreedily` runs over the whole module (`EcoControlFlowToSCF.cpp:1194`). It
  queues every op, takes at least two iterations, and runs region simplification over the whole
  module.
- Seed `applyOpPatternsGreedily` with the `eco.case`/`eco.joinpoint` ops instead (ExistingAndNewOps
  strictness), the change that took EcoPAPSimplify from 1.0 s to 72 ms.
- The current pass also acts as a module-wide dead-code pass. To stay byte-identical, run
  `simplifyRegions` per function, in parallel inside B6's chunked pass.
- Invariant: CGEN_048.

**B6. Run `EcoFoldProject` and `EcoGCPrepare` in one chunked parallel pass, and make liveness
linear.** Estimated **−0.6 to −1 s**.
- **The pass:** EcoGCPrepare does per-function work only (`EcoGCPrepare.cpp:275`). Move
  EcoMarkGCLeafCalls to just before EcoFoldProject; that is safe, since it depends only on
  passes 4, 5, 7 and 8. Then run FoldProject and GCPrepare per function in one custom
  `failableParallelForEach` pass.
  - Make the `gCensus` global (:191) atomic, or force serial when the census is enabled.
  - Update CGEN_077's text ("immediately before createEcoGCPreparePass"); behaviour is
    unchanged.
- **Liveness:** `computeLiveRoots` (`EcoGCLiveness.h:59-85`) rescans the block prefix for every
  safepoint. Replace it with one backward live-set sweep per block.

**B7. Fix the remaining per-site linear symbol lookups.** Code unchanged; small, about
−0.2 to −1 s (they are quadratic, so cheap insurance).
- `EcoCompareCaseRewrite.cpp:134` `ensureUtilsCmp3Decl`: once per rewritten compare site; the
  decl sits at the module END. Fix: a bool carried through the run.
- `EcoListTemplate.cpp:1229`: the `kFinishFwdFn` lookup is outside the `declsMade` guard. Fix:
  fold it into the guard.
- `EcoControlFlowToSCF.cpp:785` `ensureEqualDeclared`: once per string-case op. Fix: look it up
  once in `runOnOperation`.
- `EcoOps.cpp:1372` `ListMapOp::verify` uses `lookupNearestSymbolFrom`, a linear scan per
  op at parse-time verify. Fix: move the check into `verifySymbolUses(SymbolTableCollection&)`,
  as the sibling ops already do.
- `CheckEcoClosureCaptures.cpp:57` (VAL only): build one `SymbolTable` per run.

**B8. Small MLIR cleanups.** Each under 0.2 s; ship as one deletion-flavoured step.
- `createGlobalRootInitFunction` uses a recursive `module.walk(GlobalOp)`
  (`EcoToLLVMGlobals.cpp:477`); use `getOps`.
- `EcoGCPrepare.cpp:275` does the same; use `getOps`.
- Cache uncached `getenv` calls in statics (`EcoFoldProject.cpp:49`, `:91`, `:125`).
- `BFToLLVM` runs `applyPartialConversion` over the whole module (:1152); restrict it to the
  functions that contain bf ops.
- `("__eco_strlit$" + …).str()` allocates twice per site (`EcoToLLVMGlobals.cpp:877`, :886); use
  a `SmallString`.
- `g_satSigs` uses a linear `is_contained` (`EcoToLLVMClosures.cpp:3126`); use a `DenseSet`.
- `EcoRuntime::lookupSymbol` does `StringAttr::get` per runtime-call op inside Stage 2, which
  means uniquer-lock traffic. Cache decl handles in fields after `materializeAllRuntimeDecls`.

**B9. Cheaper `LoweringStats` instrumentation.** Estimated −0.1 to −1 s; measure it.
- It is always installed (`eco-boot.cpp:376`, and `--lowering-stats` defaults on).
- Every nested pass call takes `LoweringStats::mu_` (`LoweringStats.cpp:26`) plus an allocating
  `thread_local unordered_map` insert/erase (:160-187), across 98k × 3 calls.
- Accumulate per thread and merge at exit. This becomes moot for the sweeps that B2 and B6
  remove.

**B10. Parallel Stage 0 signature conversion.** Medium risk; estimated −0.5 to −0.8 s; do it
last in B.
- Stage 0's `applyFullConversion` (`EcoToLLVM.cpp:307`) visits every body op just to rewrite
  function shells and globals.
- Instead, build the converted `llvm.func` ops detached and in parallel (move the region,
  convert the entry-block types), then swap them into the module serially.
- It must reproduce `FuncOpConversionPattern`'s attribute copying exactly.

### C. LLVM-side, code unchanged

**C1. Reduce IR volume.** codegen-changing, and research first (step 0c).
- **Why:** every phase scales with the number of instructions, and the IR has grown about 40–50
  % since August.
- **Candidates:**
  - deduplicate string literals by content (one `__eco_str_N` global and one slot per literal
    OP today; `EcoToLLVMTypes.cpp:187`);
  - check whether all 25k `__closure_sat_*` thunks and 16k typed wrappers are reachable after
    DCE;
  - check whether the inline nursery and deref diamonds could share one out-of-line slow path
    per function.
- These trade compile time against runtime, so each needs its own recursive-tax check. Scope
  each one only after 0c gives counts.

**C2. Size-balanced partitions.** Estimated −1.5 s.
- `partitionOfName` (`EcoBackend.cpp:293`) is FNV-1a % N, which balances by function COUNT.
  Assign greedily by instruction count on the main thread and give workers a read-only
  name-to-partition map.
- Expected effect: drain 8.7 s → about 7.4 s. With A1, partitions also carry opt, so balance
  matters more.

**C3. Stop the per-worker `verifyModule`.** About 4 s CPU, about 0.2 s wall.
- Translation adds the "Debug Info Version" module flag, so each worker's `materializeAll` calls
  `UpgradeDebugInfo`, which runs a full `verifyModule`.
- Set LLVM's `disable-auto-upgrade-debug-info` option at startup. No DWARF is emitted for
  generated code anyway.

**C4. Make the worker re-parse cheaper.** About 12 s CPU, about 0.5 s wall; low priority.
- Every worker re-parses every global initializer and about 85k declarations from the shared
  bitcode. Serializing a second "declarations-only" blob for non-owning partitions halves that.

**C5. Translation (6.8 s), low priority.**
- `legalizeDIExpressionsRecursively` (about 1.3 s) runs inside `translateModuleToLLVMIR` and
  cannot be skipped without patching MLIR.
- Stripping locations before translation saves only about 0.3 s of `DebugTranslation`.
- `convertFunctions` is the bulk (54 %). It would need a parallel translation scheme, which is
  out of scope unless everything else is done.

### D. Infrastructure that supports the loop (fold into whichever step needs it first)

- **D1. Pass timing for the LLVM opt stage.** The A3 `PassBuilder` registers a
  `PassInstrumentationCallbacks` that accumulates per-pass times into `LoweringStats`. That gives
  the breakdown in §0.1 from every run, without `perf`.
- **D2. Split timers.** Add `createGlobalRootInitFunction` vs. strip timers in `EcoToLLVM`, so
  B3's effect is visible in the banner.

## 2. Expected trajectory (rough)

| after | wall |
|---|---|
| base | ~216 s |
| A1 (`cgu`) | ~80 s |
| + A3 | ~75 s |
| + B1–B4 | ~65 s |
| + A2 (no-assert LLVM) | ~55 s |
| + B5–B10, C2–C3 | ~50 s |

- After A1 the serial path is: MLIR (19) + translation (7) + prologue IPO (about 12) + serialize
  (6) + the partition critical path (about 30). That makes the B steps and the IPO prologue the
  next targets.
- IR volume (C1) multiplies through every phase. It is the main lever left after that.

## 3. Refuted or done: do not retry

- **Per-function MLIR pass parallelism for tiny functions (July B1):** neutral.
- **Re-anchoring EcoGCPrepare on its own nested sweep:** neutral. B6 avoids this by chunking.
- **Per-function `EcoControlFlowToSCF`:** neutral (`EcoControlFlowToSCF.cpp:1108` comment).
- **`ConvertControlFlowToLLVM` nesting:** it is ModuleOp-pinned upstream. B2 avoids this by
  using its patterns inside our own per-function conversion.
- **Emit settings:**
  - `--dev-emit-cg=1`/Less is a no-op.
  - `--dev-emit-cg=0` (FastISel) costs +6.8 % recursive tax, and falls back to SelectionDAG at
    statepoints anyway.
  - GlobalISel is not viable with statepoints.
- **`--split-codegen=24`:** slower than auto (16) with SplitModule. Recheck only if lazy-split
  changes that.
- **`--rs4gc-after-opt`:** experimental and risks REP_LLVM_001(a). Not part of this plan.
- **The DT_TEXTREL link warning:** pre-existing and by design (`EcoNativeDriver.cpp:858-870`).
  It costs milliseconds at load and nothing at compile time.
- **Done before the loop (2026-10-01):** quadratic `lookupSymbol` fixes in
  `materializeStringLiteralSlots`, eval descriptors, EcoListCursor, EcoListTemplate
  `getSymbolUses` and `installCafMemoGuard`. Wall 641 s → about 216 s.
