# Backend pipeline performance review

Performance review of the native backend pipeline: MLIR eco dialect → LLVM dialect →
LLVM IR → RS4GC → optimization → object emission → link. Measured on the self-host
compiler module (the largest real input we have) with concrete, verified findings and
a prioritized fix list.

> **Implemented 2026-07-06.** The plan below was executed. Self-host `-O2` lowering
> went **221.93 s → 81.81 s (2.71×)** by default, and **→ ~70 s (3.17×)** with the
> experimental `--rs4gc-after-opt` opt-in; `-O0` went **115 s → 37 s (3.1×)**. The
> pipeline now uses multiple cores (CPU 118% → 187–204%). Before/after numbers and
> per-change attribution are in `backendstats.txt`. Implementation status per item:
>
> | Plan item | Status | Result |
> |---|---|---|
> | A1 eval-layout + kernel-func symbol cache | ✅ shipped | EcoToLLVMPass 53.5 s → 6.5 s |
> | A2 type-table dense byte-blob globals | ✅ shipped | translation 13.6 s → 5.8 s |
> | A6 UndefinedFunction DenseSet, BFToLLVM early-out, string-counter | ✅ shipped | small; determinism |
> | C verify hygiene (drop per-pass verifier + redundant verify, release only) | ✅ shipped | MLIR pipeline 16 → 11.5 s |
> | C internalize + GlobalDCE (exe output) | ✅ shipped | LLVM backend 147 → 116 s (−32 s) |
> | C function-sections + `--gc-sections` (+ stackmap KEEP) | ✅ shipped, opt-in | −2.7% binary size |
> | B2 SplitModule parallel object emission (+ stackmap multi-blob parse) | ✅ shipped, default-auto | LLVM backend 116 → 62 s (−54 s) |
> | item 6 RS4GC-after-opt | ✅ shipped, **off-by-default** experimental | LLVM backend 62 → 51 s (−11 s) |
> | A3 PAP greedy→walk, A4 GC-liveness sweep, A5 case use-list | ⏸ deferred | sub-0.5 s now; A4 GC-critical |
> | B1 per-function pass parallelism | ❌ measured neutral → reverted | 64k tiny fns: scheduling overhead offsets gain |
> | B2b per-partition opt | ⏸ deferred | would degrade produced-binary runtime (it is the compiler) |
> | -O1 dev default | ❌ measured non-win | -O1 ≈ -O2; -O0 is the real 3× dev lever |
>
> Correctness: JIT suite 1529/1547 (18 failures are sandbox-unreachable elm-http
> network tests; 288/288 codegen), and every backend-reaching AOT E2E test passes
> its CHECK oracle. Split codegen verified N=1 vs N=8 byte-identical on 15 GC-heavy
> modules and through a forced-2-way ADT/GC AOT sweep. The new runtime multi-blob
> stackmap parser (`StackMap::parse`) is a strict superset — single-blob binaries
> parse identically.
>
> New `eco-boot-native` flags (also on `EcoNativeOptions` for the unified `eco`):
> `--split-codegen=N` (0=auto, default), `--gc-sections` (off), `--rs4gc-after-opt`
> (off). The GC-critical RS4GC reorder stays off until an
> `ECO_LOWERING_VALIDATION` + heavy-GC-stress campaign signs it off.

## Method

- **Input:** `build/compiler/build-kernel/bin/eco-compiler.mlir` — 12.2 MB MLIR
  bytecode, whole-program module. Lowers to **85,686 LLVM functions** (301 MB of
  textual LLVM IR after O2).
- **Binary:** `build/runtime/src/codegen/eco-boot-native`, RelWithDebInfo,
  `ECO_LOWERING_VALIDATION=OFF`, LLVM/MLIR 21.1.8.
- **Machine:** 24 cores, 15 GB RAM.
- **Measurement:** `--lowering-stats` phase/pass breakdown, `/usr/bin/time`,
  gdb stack sampling (perf is blocked in the sandbox), plus source review of every
  pass in `runtime/src/codegen/Passes/`.

## Measured baseline (-O 2, full exe)

Wall clock **224 s**, CPU utilization **118 %** (i.e. effectively single-threaded on a
24-core machine), peak RSS 2.6 GB.

| Phase | Time | % |
|---|---|---|
| LLVM backend (RS4GC + opt + object emission) | 143.1 s | 64.5 % |
| — of which RS4GC | ~5 s | 2 % |
| — of which O2 pipeline (`makeOptimizingTransformer`) | ~53 s | 24 % |
| — of which object emission (ISel/codegen) | **~85 s** | **38 %** |
| MLIR lowering pipeline | 63.4 s | 28.6 % |
| — of which `EcoToLLVMPass` (dialect conversion) | **53.5 s** | **24 %** |
| — all other MLIR passes combined | ~10 s | 4.5 % |
| MLIR → LLVM IR translation | 13.6 s | 6.1 % |
| MLIR parse + verify (bytecode) | 1.0 s | 0.5 % |
| Link (ld) | 0.9 s | 0.4 % |

The RS4GC/opt/emission split comes from an `--emit=llvm -O 2` run, which times those
scopes separately (RS4GC 4.9 s, O2 53.2 s; emission is the remainder of the 143 s).

At `-O 0` the same input takes **117 s** (MLIR pipeline unchanged at 64.5 s, LLVM
backend drops to 34.8 s). So the pipeline is dominated by four items: object
emission (~85 s), the Eco→LLVM dialect conversion (~53 s), the O2 pipeline (~53 s),
and MLIR→LLVM-IR translation (~14 s). Everything else is noise.

The only parallelism today is MLIR's per-function verifier/canonicalizer threading
(the 18 % over 100 % CPU). All eco passes are `OperationPass<ModuleOp>`, the LLVM
opt pipeline is one module pass pipeline, and object emission is one
`addPassesToEmitFile` run over one module.

---

## Findings

### A. Algorithmic hotspots (verified in source; A1/A2 confirmed by sampling/counting)

#### A1. `getOrCreateEvalLayout` does an O(module) symbol scan per closure call site — likely the bulk of the 53 s conversion

`Passes/EcoToLLVMClosures.cpp:1364`:

```cpp
if (module.lookupSymbol<LLVM::GlobalOp>(name)) { ... }
```

`ModuleOp::lookupSymbol` without a `SymbolTable` is a **linear walk over every
top-level op**. This helper runs on every closure apply path
(`emitInlineClosureCall`, `lowerSegmentationUnknown`, `lowerGenericApply`,
`PapExtendOpLowering`). Measured on the self-host module: **42,809 references** to
`__eco_eval_layout_*` globals, but only **59 distinct layouts** exist. That is
~42,809 × ~86,000 ≈ **3.7 billion symbol-name comparisons** to service what a
59-entry cache would answer in O(1). The created globals are also never registered
in `EcoRuntime::symCache` — which exists precisely to prevent this (the same
pathology is documented as already fixed once in `EcoToLLVMRuntime.cpp:19-27`:
"92K calls × 49K functions … ~4.5B comparisons").

Compounding it, the symbol name is rebuilt with `std::string` concatenation on
every call (`EcoToLLVMClosures.cpp:1358-1362`) even on the hit path.

**Fix (small):** thread `EcoRuntime &` into `getOrCreateEvalLayout` (all callers
have it), key a `DenseMap` on `(resultKind, kinds)` or at least use
`runtime.lookupSymbol` + `cacheSymbol`. Expected effect: removes most of the 53 s
`EcoToLLVMPass` time. This is the single highest-leverage fix in the repo.

The same bug class, smaller: `Passes/EcoToLLVMFunc.cpp:39` —
`module.lookupSymbol<LLVM::LLVMFuncOp>` per kernel `func.func` inside the
conversion pattern. Route through `EcoRuntime::symCache` too.

#### A2. Type-table globals lowered as `insertvalue` chains → quadratic constant folding in translation (~14 s phase)

`Passes/EcoToLLVMGlobals.cpp:196-445` materializes fully-static byte data (the type
graph: `uint8_t data[12]` per entry, plus fields/ctors/strings arrays) as chained
`LLVM::InsertValueOp`s — ~20-30 ops per entry. During MLIR→LLVM-IR translation,
each `insertvalue` constant-fold **copies and re-uniques the whole aggregate**
(`ConstantFoldInsertValueInstruction` + `ConstantUniqueMap`) — O(n²) in array
length. gdb sampling caught the translation phase inside exactly this stack twice
out of four samples.

**Fix (small):** serialize each array to raw bytes in C++ (the code already
hand-specifies little-endian layout) and emit one `LLVM::GlobalOp` with a
`DenseElementsAttr`/string initializer over `[N x i8]` — the same approach
`StringLiteralOpLowering` already uses. Should collapse most of the 13.6 s
translation phase and shrink the module the O2 pipeline sees.

#### A3. `EcoPAPSimplify` drives the whole 12 MB module through the greedy rewrite driver for two local patterns

`Passes/EcoPAPSimplify.cpp:292`: `applyPatternsGreedily(module, …)` seeds a
worklist with *every op in the program* (fold + DCE attempts each) to rewrite only
`eco.papExtend` ops, and leans on driver DCE as a garbage collector for the fused
chains. **Fix:** collect `PapExtendOp`s in one walk, process them with a small
local worklist, erase dead `papCreate`/`papExtend` explicitly. (Measured cost today
is ~1.2 s; the fix also unlocks making it a parallel per-function pass — see B1.)

#### A4. GC liveness is O(block²)

`Passes/EcoGCLiveness.h:32-66` (`computeLiveRoots`), called per safepoint and per
alloc-group leader from `EcoGCPrepare.cpp:255,329`: for each safepoint at position
k in a block, it rescans all k preceding ops and queries `isDeadAfter` (O(#users))
per candidate — quadratic in block size for call-dense blocks. **Fix:** one
backward sweep per block maintaining a live set, snapshotting at safepoints —
O(N + Σ snapshot sizes). Also repairs the validation-build
`EcoGCLivenessAuditPass`, which shares the helper.

#### A5. Case lowering rescans regions per case

`Passes/EcoToLLVMControlFlow.cpp:765-817` (and the analogous loops at
`:238-272`, `:514-549`): each lowered `eco.case` iterates the parent region from
the beginning to find its own block window, then calls `replaceUsesOfWith` on
every op in the window — O(cases × blocks) per function plus O(window ops) per
case. **Fix:** replace scrutinee uses via the use list
(`replaceUsesWithIf`), and track the blocks the lowering itself created instead of
rescanning. Also `mergeBlock->getOperations().size() == 1` at `:208/:485/:737` is
O(n) (`iplist::size`); use `llvm::hasSingleElement`.

`Passes/EcoControlFlowToSCF.cpp` has the same family of issues: alternatives are
**cloned** into new SCF ops (`:271-279`, `:441-450`), so ops under d levels of
case nesting are cloned d times; and `containsNestedStringCase` (`:105-112`) walks
the whole subtree on every greedy re-attempt. **Fix:** move blocks with
`inlineRegionBefore` instead of cloning, and convert bottom-up with a single
post-order walk instead of the greedy driver.

#### A6. Small verified items

- `Passes/UndefinedFunction.cpp:44-70`: `std::set<std::string>` + `.str()` copies
  for ~86k names, and a filtered `module.walk` that visits every op to find
  top-level `func.func`s. Use `DenseSet<StringAttr>` (identity compare on uniqued
  attrs) and `module.getBody()->getOps<func::FuncOp>()`.
- `Passes/BFToLLVM.cpp:1136`: whole-module `applyPartialConversion` + 10
  unconditional runtime declarations for a dialect that appears only in
  bytes-codec functions. Early-out when no `bf.*` ops exist. Separately, the
  `bf.read.*` lowerings emit byte-wise load+zext+shl+or chains (~22-40 ops)
  while the writes correctly use one unaligned store + `ByteSwapOp`; mirroring
  that in reads is a 5-10× IR reduction in decoder code.
- `Passes/EcoToLLVMClosures.cpp:1709`: `emitWarning` per unknown-dispatch closure
  call — O(M) diagnostics if metadata propagation regresses; aggregate it.
- `Passes/EcoToLLVMTypes.cpp:87`: function-local `static int stringCounter` —
  non-reentrant across compilations in one process, hurts determinism.
- `RCElimination.cpp`: six sequential `isa<>` tests per op in a serial
  module walk for a check that normally finds nothing — fuse into one variadic
  `isa<...>` and/or make it a parallel function pass.

### B. Parallelism (the structural problem)

#### B1. Every eco pass is a module pass, so MLIR's pass parallelism is unused

MLIR parallelizes `OperationPass<func::FuncOp>` across the context thread pool
automatically; `OperationPass<ModuleOp>` serializes. Verified per pass:

| Pass | Per-function? | Blocker |
|---|---|---|
| `JoinpointNormalization` | Yes, trivially | none — only sets attrs inside functions |
| `EcoGCPrepare` | Yes, trivially | already structured as `module.walk([](func::FuncOp))` |
| `EcoControlFlowToSCF` | Yes, after one hoist | `ensureEqualDeclared` inserts one module symbol — pre-declare it once |
| `RCElimination` | Yes | none |
| `EcoPAPSimplify` | Yes, after A3 restructure | reads sibling signatures — precompute a read-only map first |
| `BFToLLVM` | Mostly | declarations already hoisted to a prologue |
| `UndefinedFunction` | Keep module scope | but parallelize the per-call check against the read-only set |
| `EcoToLLVMPass` | Not as-is | creates module symbols/globals mid-conversion; see B3 |

Re-anchoring is mostly mechanical (`pm.addNestedPass<func::FuncOp>` +
`OperationPass<func::FuncOp>`). Today these passes are only ~7 s combined (A1
dwarfs them); after the A-fixes land, this is what keeps the MLIR side scaling.

#### B2. Object emission (~85 s) and the O2 pipeline (~53 s) run on one module on one thread

This is the biggest opportunity in absolute terms. LLVM's answer is module
splitting: `llvm::SplitModule` (present in the installed LLVM 21;
`ParallelCG.h` was removed upstream, but it was a ~100-line wrapper) partitions a
module by symbol hash, promoting locals as needed. Plan:

1. After RS4GC (or after opt), `SplitModule(M, N, …)` with N ≈ min(cores, 8-16).
2. Round-trip each partition through bitcode into a fresh `LLVMContext` per
   worker thread (contexts are not thread-safe; this is what ParallelCG did).
3. Run `addPassesToEmitFile` per partition concurrently → N object files.
4. Pass all N objects to the existing `linkExecutable` (args already take a list
   position; trivial change).

To also parallelize the *optimization* pipeline, run
`makeOptimizingTransformer` per partition instead of pre-split. That trades some
cross-partition inlining for wall clock (rustc's codegen-units make the same
trade; N=8-16 keeps the loss modest, and the frontend already does its own
inlining at the Elm level).

**Two caveats, both manageable:**
- `runtime/src/allocator/StackMap.cpp:120` parses `.llvm_stackmaps` as a single
  blob (one header). N objects concatenate N blobs at link; the parser needs an
  outer loop "while bytes remain, parse next blob". Same fix benefits the
  Stage-D shared-library path.
- The `eco-gc` GCStrategy registration is process-global (already handled by the
  static linker trick) — fine across threads.

Expected: 85 s emission → ~10-15 s at N=8; O2 53 s → similar factor if split
before opt.

#### B3. Longer term: split the Eco→LLVM conversion itself

`EcoToLLVMPass` must stay module-scoped today because patterns create module-level
artifacts on demand (runtime fn declarations via `EcoRuntime::getOrCreate*`,
string-literal globals, closure wrappers, eval layouts). The path to parallelism:
pre-create all runtime declarations in a cheap prologue pass (the set is static —
it's the `RuntimeSymbols` list), pre-scan for string literals/layouts, then run
`applyFullConversion` per function in parallel. Worth doing only after A1/A2 land
and if the conversion is still hot.

### C. Pipeline-level waste

- **RS4GC runs *before* the O2 pipeline** (`EcoBackend.cpp:runEcoBackend`,
  `eco-boot.cpp`). LLVM's statepoint design intends `RewriteStatepointsForGC` to
  run *late*, after optimization: gdb samples show InstCombine grinding through
  `gc.relocate`/statepoint plumbing, every optimization pass pays for the
  statepoint-expanded IR, and statepoints pin values/inhibit motion, hurting
  output quality as well as compile time. Reordering to opt→RS4GC(→light cleanup)
  is standard practice, but verify against the REP_*/HEAP_* invariants and the
  addrspace(1) verifier assumptions first (the abstract addrspace(1) form is
  exactly what upstream expects the optimizer to see, so this should be
  compatible in principle).
- **Per-pass verification:** the `PassManager` verifier defaults to on, running a
  full-module verify after each of ~13 top-level passes. Parse already verifies,
  and `pipelineFromMlirModule` runs a *third* explicit `verify(*module)` before
  the pipeline. Gate per-pass verification behind `ECO_LOWERING_VALIDATION` (or a
  flag) and drop the redundant explicit verify; a full verify costs O(module)
  each time (parse+verify of this module is ~1 s, so this is a several-second
  saving, not a headline one).
- **Linkage/internalization:** only 21,823 of 85,686 functions are `internal`.
  ~64k Elm functions get external linkage, which blocks `GlobalDCE`, weakens
  IPO (no argpromotion/deletion of externally-visible functions), and keeps every
  function in the binary (no `-ffunction-sections` + `--gc-sections` either).
  For executable output, internalize everything except `eco_main`,
  `__eco_root_module`, the globals-init entry, and the embed/N-API entry points.
  This is both a compile-time (DCE before opt/codegen) and binary-size win.
- **IR volume:** per-slot `llvm.mlir.constant`s in capture/field loops
  (`EcoToLLVMClosures.cpp:877,1015-1075`, `EcoToLLVMValueAgg.cpp`,
  `EcoToLLVMHeap.cpp:816,953`) and the byte-wise `bf.read.*` chains multiply the
  op count every downstream pass must chew.
- **-O default:** `EcoNativeOptions.optLevel = 2` everywhere. -O0 is 117 s vs
  224 s on the same input. A `-O1`/dev-mode default for `eco make` iterating
  builds (with -O2 for release) is a free 2× until the structural fixes land.

### D. What is already fine

- Input is MLIR **bytecode**, parse is 1 s — not a bottleneck.
- Link is 0.9 s (direct ld/lld invocation) — not a bottleneck.
- `EcoRuntime::symCache` and `getOrCreateWrapper` are correctly O(1) — the bugs
  are the two call sites that bypass the cache (A1).
- The AOT E2E test suite and the JIT test runner already parallelize across
  *processes*; the problem is single-program latency, which is what everything
  above addresses.
- Peak RSS 2.6 GB is comfortable; module splitting adds transient copies but
  partitions can be freed as they finish.

---

## Prioritized plan

Estimated single-program full build (self-host module, -O 2): 224 s today.

| # | Change | Effort | Est. saving |
|---|---|---|---|
| 1 | A1: cache eval-layouts (+ kernel-func lookup) in `EcoRuntime` | hours | ~30-45 s |
| 2 | A2: type-table as dense byte-blob globals | hours | ~8-12 s |
| 3 | C: `-O 1`/dev default; disable per-pass verify + redundant verify | hours | ~5-10 s (and 2× at -O0/1) |
| 4 | B2: SplitModule parallel codegen (emission only) + stackmap multi-blob parse | days | ~70 s (85→~12 s at N=8) |
| 5 | B2b: per-partition opt pipeline | days | ~40 s (53→~10 s) |
| 6 | C: RS4GC after opt (investigate invariants) | days | 10-20 % of opt, better code |
| 7 | A3-A6 + B1: pass restructures + per-function re-anchoring | days | several s now; keeps MLIR side scaling |
| 8 | C: internalize + GlobalDCE + function-sections/gc-sections | days | opt/codegen ∝ live code; binary size |
| 9 | B3: parallel per-function dialect conversion | weeks | remaining conversion time / N |

Items 1-3 are quick wins worth doing immediately (~185 s → ~130 s). Items 4-5 are
the structural change that actually uses the machine (~130 s → **~35-45 s**).
Items 6-9 push toward ~20-30 s and keep the pipeline scaling as programs grow.

## Reproducing the measurements

```bash
# Full pipeline with phase/pass breakdown (writes stats to stderr):
build/runtime/src/codegen/eco-boot-native --lowering-stats \
    -o /tmp/out.bin build/compiler/build-kernel/bin/eco-compiler.mlir

# Split RS4GC vs O2 timing:
eco-boot-native --lowering-stats --emit=llvm -O 2 -o /tmp/out.ll <same input>

# Note: -O takes a separate argument (-O 2, not -O2).
```
