# Backend round 4: serial-spine optimizations

Implementation plan for the candidates in
`design_docs/backend-optimization-candidates.md` (investigation 2026-07-07).
Predecessors: `backend-pipeline-performance.md` (222→82s),
`plans/parallel-llvm-opt-partitioning.md` (82→41.8s),
`plans/backend-serial-floor-pipelining.md` (41.8→31s, lazy split default).

## STATUS: IMPLEMENTED & VALIDATED (2026-07-07) — all M1–M7 shipped

Results log: `backendstats-round4.txt`. **Default dev wall 28.95s → 26.4s
(−8.8%)**; M3 opt-in flags stack ~−2s more; M2 artifact −2.65%; M6 RSS −0.27GB.
Gates green: full JIT E2E **1547/1547**, AOT self-host binary functional-identical.

| M | what shipped | effect | verdict |
|---|---|---|---|
| M1 | `disableVerification=true` in translation (3 drivers, gated) | −0.94s wall | SHIP |
| M2 | strip `_operand_types` at bytecode encode (`AttrType.bytecodeAttrs`) | artifact −2.65% | SHIP |
| M3 | `--dev-emit-cg` / `--dev-opt-o1` flags (default OFF) | opt-in −2.2s | SHIP opt-in |
| M4 | drop FnAttrs pair (cheap-IPO) + func canonicalizer | −~1.5s wall, exe +0.28% | SHIP |
| M5 | fuse walks + `flushGroup` + utf16 cache | −0.18s wall | SHIP |
| M6 | free MLIR/context/buffer before workers | RSS −0.27GB | SHIP |
| M7 | env-gated `ECO_ECO2LLVM_STATS` timers | applyFullConversion=89.7% | SHIP + design |

Deferred (documented, not shipped): M3 default-flip (recursive-tax gate);
function-parallel EcoToLLVM → `plans/eco-to-llvm-parallel-conversion.md`;
M2 frontend PhaseMlir precise benchmark; short-symbol mode.

## Baseline & measurement protocol (applies to every milestone)

Baseline (2026-07-07, 24-core box, N=24 auto partitions):

```
B=build/runtime/src/codegen/eco-boot-native
IN=build/compiler/build-kernel/bin/eco-compiler.mlir
/usr/bin/time -v $B --lowering-stats -O 2 --parallel-opt=dev -o /tmp/eco-probe $IN
# => wall 28.77s, CPU 466%, RSS 4.9GB
# spine: MLIR 9.43 | translation 5.64 | cheap-IPO 4.25 | drain 4.45
#        | ext+ser 1.30 | link 1.14 | parse 0.73 | internalize+DCE 0.38
# passes: EcoToLLVM 5.31 (module,serial) | Arith 3.21 / SCF 3.00 /
#         Canonicalizer 2.82 (nested,parallel sums) | EcoCFToSCF 1.24 |
#         CFToLLVM 0.92 | GCPrepare 0.52 | Reconcile 0.24
# workers (summed/24): emit 59.1 | opt 20.0 | RS4GC 4.6 | lazy extract 4.1
```

Record every milestone's before/after in `backendstats-runs.txt` (append,
same format as prior rounds).

**Functional gates** (run after each milestone that changes emitted code or
the pipeline; M1/M4/M5 need the full set, M2 needs the frontend set too):
1. `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt` —
   run ONCE, grep the file for failures (per CLAUDE.md test discipline).
   Expected JIT E2E: 1547 minus known elm-http sandbox failures.
2. AOT elm-core sweep, serial, fresh cache per mode (dev and cgu via
   `ECO_AOT_EXTRA_FLAGS`, JOBS=1, `rm -rf build/test/aot-e2e/*/eco-stuff`
   between modes — NOT `rm -rf ~/.eco`). Expected 99/99 each, 0 backend fails.
3. Self-host functional identity: build eco-compiler with the changed
   backend, run it, compare banner+GC-profile output byte-for-byte against
   the pre-change binary (strongest gate; only timings may differ).

**Invariants**: none of M1–M6 changes lowering semantics. M3 changes the
LLVM *codegen* level only — RS4GC statepoint output must still lower
correctly (REP_LLVM_001: `!eco.value`⇒`ptr addrspace(1)` and statepoint
relocation correctness is enforced at IR level BEFORE codegen; codegen level
does not touch it, but the gate suite must pass to prove SelectionDAG/
FastISel handle the STATEPOINT pseudos at the lower level). Re-read
`design_docs/invariants.csv` REP_LLVM_001 before starting M3.

---

## M1 — Disable LLVM-IR verification inside translation  (2 hrs, est −1 to −2s)

**Fact (verified):** `mlir::translateModuleToLLVMIR` verifies the produced
85k-function LLVM module unless `disableVerification=true`
(`/opt/llvm-mlir/include/mlir/Target/LLVMIR/Export.h:29`, 4th param,
default false). All three AOT drivers call the 2-arg form.

**Edits** — three call sites, identical pattern:
- `runtime/src/codegen/eco-boot.cpp:382`
- `runtime/src/codegen/EcoNativeDriver.cpp:120`
- `runtime/src/codegen/ecoc.cpp:211`

```cpp
    // Skip the whole-module LLVM verifier on the translation output in
    // release: the MLIR pipeline's own gating already validated the input,
    // and validation builds re-enable it. Mirrors pm.enableVerifier(false).
#ifdef ECO_LOWERING_VALIDATION
    constexpr bool kDisableLLVMVerify = false;
#else
    constexpr bool kDisableLLVMVerify = true;
#endif
    auto llvmModule = translateModuleToLLVMIR(module, llvmContext,
                                              "LLVMDialectModule",
                                              kDisableLLVMVerify);
```

**Do NOT touch** `runtime/src/jit/EcoJIT.cpp:283` — the JIT path is the
test-runner path (`test/test` via EcoRunner); keeping verification there is
free insurance on small modules.

**Macro visibility:** `ECO_LOWERING_VALIDATION` is target-scoped
(`runtime/src/codegen/CMakeLists.txt:404,531,616,849,1579`). ecoc (531) and
eco-boot-native (1579) are covered; confirm the target at line 849 is the
one compiling `EcoNativeDriver.cpp` before relying on the gate (if not, add
`target_compile_definitions` for it inside the same `if()` block).

**Measure:** "MLIR -> LLVM IR translation" stat before/after. **Gate:** full
suite + AOT sweep. **Rollback:** revert the 3 hunks.

---

## M2 — Strip `_operand_types` from bytecode encoding  (0.5–1 day, frontend PhaseMlir + artifact size + parse)

**Facts (verified):**
- Emitted at 99 sites across 7 Elm files; sole reader is the Elm textual
  printer `compiler/src/Mlir/Pretty.elm:253-256` (generic-form operand
  types). No C++ reader exists (only a doc mention, `Ops.td:1261`, where it
  is *documented as optional* for `pap_create_group` and absent from the
  ODS `arguments` list — verifiers cannot require it).
- `_fast_evaluator` IS read by the backend (`EcoOps.cpp:57,63`) — strip must
  be exact-name, never a prefix filter.
- Attr collection has a single choke point `collectOp`
  (`compiler/src/Mlir/Bytecode/AttrType.elm:565-578`, reached from both the
  streaming accumulator at :262 and the module fold at :305); encoding has a
  single consumer `encodeOp` (`compiler/src/Mlir/Bytecode/IrSection.elm:387-448`,
  `hasAttrs` at :396, `dictAttrIndex` at :448).

**Design constraint:** the attr table is keyed by the *dict value* —
`dictAttrIndex op.attrs` must be called with exactly the dict that
`collectOp` registered, else lookup misses. Therefore one shared helper used
by BOTH sides:

**Edits:**
1. `AttrType.elm` — add + export (update the module `exposing` list at :2/:14):

```elm
{-| Attributes as actually encoded into bytecode. `_operand_types` is a
printer-only aid (Mlir.Pretty reads it to render generic-form operand
types); neither the bytecode encoder nor the C++ backend reads it, so it
is stripped here. MUST be applied identically in collectOp and in
IrSection.encodeOp so attr-table keys and lookups agree.
-}
encodedAttrs : Dict String MlirAttr -> Dict String MlirAttr
encodedAttrs attrs =
    Dict.remove "_operand_types" attrs
```

2. `AttrType.elm collectOp` (:565-578): bind
   `attrs = encodedAttrs op.attrs` and use `attrs` for the `Dict.isEmpty`
   check, `addDictAttrEntry`, and `collectDictContents` (this is what stops
   the nested TypeAttr entries from ever entering the table).
3. `IrSection.elm encodeOp`: bind `attrs = AttrType.encodedAttrs op.attrs`;
   use it for `hasAttrs` (:396) and `dictAttrIndex` (:448). Side benefit:
   ops whose ONLY attr is `_operand_types` (every plain `eco.yield`,
   `Ops.elm:560`) drop their attr-dict reference entirely.
4. Grep first, adjust if hit: `grep -rn "_operand_types" compiler/tests/` —
   any bytecode round-trip test asserting the attr survives must be updated
   to assert the opposite.

**Build note:** compiler .elm change ⇒ rebuild via
`cmake --build build --target full` (regenerates .mlir; never trust stale
`--target check`). If a compiler source file is *deleted*, reconfigure with
`cmake --preset build` first (non-CONFIGURE_DEPENDS glob) — not needed here.

**Measure:**
- artifact size: `build/compiler/build-kernel/bin/eco-compiler.mlir`
  (baseline 12,016,118 bytes);
- backend "MLIR parse + verify" stat (baseline 0.73s);
- frontend: `eco make --stats` MLIR-codegen row (baseline ~20.3s PhaseMlir).

**Gates:** frontend `cmake --build build --target elm-tests` + full E2E +
AOT sweep. Stage-diff self-host gate is unaffected: it compares outputs of
the *same* compiler across stages, and both strip identically.
**Rollback:** revert; bytecode format itself is unchanged (it's just an
absent optional attribute), so mixed old/new artifacts stay parseable.

---

## M3 — Dev-tier cheaper object emission + O1 IR tier  (1–2 days, est −1.5 to −2.5s)

Workers cost ~3.7s each; emit = 59.1s of the 87.9s summed worker time.
The TM is created per worker at the job's opt level and used for BOTH
partition opt and emit.

**Facts (verified):**
- Worker TM creation: `EcoBackend.cpp:474` (lazy path, default) and `:240`
  (SplitModule fallback path) — `createEcoTargetMachine(*mod, optLevel)`.
- `createEcoTargetMachine` (`EcoBackend.cpp:555-591`) maps the unsigned
  level straight to `CodeGenOptLevel` (:575). CPU/features stay pinned
  (`kEcoTargetCPU` — do not disturb; see AVX-512 leak history).
- Dev IR tier: `runNoInlineFunctionPipeline` (`EcoBackend.cpp:147-166`)
  uses `toOptLevel(optLevel)` ⇒ O2 today; `toOptLevel` (:101-108) already
  maps `Less→O1`.

**Edits:**
1. `EcoBackend.h` `EcoBackendJob`: add
   `unsigned devEmitCodeGenLevel = ~0u; // ~0 = follow optLevel (Dev tier only)`
   and `bool devOptO1 = false;`.
2. Plumb from `eco-boot.cpp` cl::opts `--dev-emit-cg=<0|1|2>` (default: no
   override) and `--dev-opt-o1` (default off), and from
   `EcoNativeOptions` (mirror how `parallelOpt`/`splitCodegen` are plumbed —
   grep `splitCodegen` in `EcoNativeDriver.cpp` and `EcoNativeAPI.h` and
   copy that path).
3. In BOTH worker bodies (`EcoBackend.cpp:474` and `:240`):

```cpp
unsigned emitLevel = static_cast<unsigned>(optLevel);
if (perPartitionMode == ParallelOpt::Dev && devEmitCG != ~0u)
    emitLevel = devEmitCG;
auto tm = createEcoTargetMachine(*mod, emitLevel);
```

   (thread `devEmitCG` down as a parameter next to `perPartitionMode`).
   Document in a comment that this TM also feeds the Dev IR pipeline's
   PassBuilder TTI hooks — acceptable inside the dev tier.
4. In `runNoInlineFunctionPipeline`, when `devOptO1` is set pass
   `OptimizationLevel::O1` instead of `toOptLevel(optLevel)` (thread the
   bool through `optimizePartitionModule`).

**Sweep protocol** (self-host, N auto, three runs each, record medians):
`--dev-emit-cg` ∈ {unset, 1, 0} × `--dev-opt-o1` ∈ {off, on}. Watch:
partition emit sum, partition opt sum, drain, total wall, exe size.
- Expect `cg=1` (Less) to cut emit noticeably (greedy RA stays; late machine
  opts shrink); `cg=0` (None ⇒ FastISel+RegAllocFast) may win more OR thrash
  on statepoint fallbacks — measure, don't assume.
**Decision gate:** flip the winning combination to the Dev-tier default only
if AOT dev sweep is 99/99 AND self-host functional identity holds AND the
dev-built compiler's own runtime (recursive tax: rebuild self with the
dev binary, time it) regresses <3%.
**Rollback:** flags default to today's behavior; default flip is one line.

---

## M4 — Attribution experiments: Canonicalizer, cheap-IPO members, double GlobalDCE  (1–2 days, est 0 to −1.5s; data decides)

Three A/Bs sharing one temporary-instrumentation patch. These are
*measurements first* — deletions only ship if the numbers say so.

**4a. Per-pass attribution inside `runCheapModuleIPO`** (`EcoBackend.cpp:120-140`).
Temporarily split the single `MPM.run` into five sequential runs, each in a
`MaybeScope` (`stats` must be threaded in — pass `job.stats` from the call
site at :701):

```cpp
auto runOne = [&](const char *name, auto pass) {
    MaybeScope s(stats, name);
    ModulePassManager one; one.addPass(std::move(pass)); one.run(m, MAM);
};
runOne("    cheap-IPO: IPSCCP", IPSCCPPass());
runOne("    cheap-IPO: GlobalOpt", GlobalOptPass());
...
```

Caveat: separate runs re-compute shared analyses, inflating totals slightly
— fine for *attribution*, don't ship this shape. Keep behind
`#ifdef ECO_BACKEND_ATTRIBUTION` or a local branch.
- If `PostOrderFunctionAttrs`+`ReversePostOrderFunctionAttrs` ≥0.8s: A/B
  drop them (comment out `EcoBackend.cpp:135-137`), rebuild, run the
  **recursive-tax** protocol (backendstats-runs.txt "Reproduce" section) —
  ship removal only if produced-binary self-compile regresses <1%.
- If trailing `GlobalDCE` <0.2s: close the double-DCE candidate as WONTFIX
  (both DCEs pull weight: driver-side one shrinks cheap-IPO input at
  `eco-boot.cpp:757`/`EcoNativeDriver.cpp:221`; IPO-side one strips
  newly-dead code before the whole-module serialize that every worker
  parses). If ≥0.4s: try moving it per-partition (workers own their
  globals post-externalization; externalized symbols stay visible).

**4b. Canonicalizer A/B** (`EcoPipeline.cpp:76`). Comment out
`pm.addNestedPass<func::FuncOp>(createCanonicalizerPass())`, rebuild
(C++-only ⇒ `--target check` acceptable here), and measure the FULL
downstream chain, not just the MLIR phase: MLIR phase, translation, ext+ser,
RS4GC sum, opt sum, emit sum, total, exe size. The canonicalizer also DCEs —
removal may grow every later phase and lose net. Also capture op-count
before/after canonicalize once (temporary `module.walk` counter or
`-mlir-pass-statistics`) — a large delta means the *emitter* produces
removable IR: file follow-up against the MLIR generator instead
(design doc §B4), which would shrink bytecode AND time.
**Ship** removal only on ≥0.3s net wall win with no exe-size/functional
regression across dev AND cgu AND none modes.

---

## M5 — Micro-algorithm batch  (1 day, est −0.3 to −0.7s aggregate)

One PR, verified sites, behavior-preserving. Full gates once at the end.

**5a. Fuse the two post-conversion module walks**
(`Passes/EcoToLLVM.cpp:363-367` + `:373-384`, verified adjacent):

```cpp
module.walk([&](LLVM::LLVMFuncOp func) {
    if (func.isExternal()) return;
    if (!func.getGarbageCollector()) func.setGarbageCollector("eco-gc");
    if (!shadowRootFuncs.empty() &&
        shadowRootFuncs.contains(func.getSymName())) {
        OpBuilder builder(func.getContext());
        auto frame = installShadowRootPrologue(func, builder, runtime);
        if (frame.basePtr) {
            for (auto &entry : frame.slotForArg)
                rewriteUsesViaShadowSlot(frame, entry.first, builder);
            emitShadowRootEpilogues(frame, func, builder, runtime);
        }
    }
});
```

(Original walk 1 touched external funcs' GC attr — no: it checked
`!func.isExternal()` too; semantics identical.)

**5b. Stop rebuilding the group set per alloc op**
(`Passes/EcoGCPrepare.cpp:199-209`, verified): add
`llvm::SmallPtrSet<Operation*, 8> currentGroupSet;` next to `currentGroup`;
the lambda drops its local set and queries `currentGroupSet`; then update
every `currentGroup` mutation in the enclosing function —
`push_back` ⇒ `insert`, group-close/`std::move` ⇒ `clear()` (grep
`currentGroup` in the file; ~5 touch points including the tail flush).
Typical groups are ≤4 ops so the win is modest — it's correctness-neutral
hygiene; don't over-claim.

**5c. Cache UTF-16 conversions + cheaper global names in string-case
lowering** (`Passes/EcoToLLVMControlFlow.cpp:366-472`): add a
pass-lifetime `llvm::StringMap<std::vector<uint16_t>>` to the existing
`cfCtx` (already threaded into `populateEcoControlFlowPatterns`,
`EcoToLLVM.cpp` pattern setup) keyed by pattern content; build global names
with `llvm::SmallString<48> + raw_svector_ostream` instead of two
`std::to_string` concats.

**5d (optional). `lookupSymbol(StringAttr)` overloads**
(`Passes/EcoToLLVMInternal.h:301-314`): add overloads taking a pre-made
`mlir::StringAttr`; convert only call sites that look up the same name
repeatedly in a loop (survey first with grep; if none loop, skip — the
interning cost is already small).

**Explicitly dropped from the batch:** the `EcoToLLVMHeap.cpp:1853`
alloc-group scan rewrite — the 4-level loop encodes *per-block ordered*
grouping; collecting leaders via a type-filtered walk changes iteration
semantics. Revisit only if M7's instrumentation shows `lowerAllocGroups`
is hot, and then with the ordering constraint in the design.

---

## M6 — Release MLIR-side memory before the worker phase  (0.5–1 day, indirect: worker scaling / RSS)

RSS peaks at 4.9GB with 1.47M minor faults; workers are mem-bw bound
(466% CPU of 2400%). The MLIR module + context + input buffer stay alive
for the whole run.

**Steps:**
1. In `eco-boot.cpp` main flow and `EcoNativeDriver.cpp`: locate the
   `OwningOpRef<ModuleOp>` + `MLIRContext` lifetimes; after
   `translateToLLVMIR` returns (the `llvm::Module` depends only on
   `llvmContext`), explicitly `moduleRef = nullptr;` and, if the context is
   locally owned, scope it to die there too. Free the parsed source
   `MemoryBuffer` likewise.
2. Measure `/usr/bin/time -v` RSS + total wall before/after. Ship if RSS
   drops ≥0.5GB and wall doesn't regress; treat wall improvement as bonus.
   Risk: something downstream secretly reads MLIR state (e.g. stats
   printing op counts) — compile-and-gate catches it.

---

## M7 — EcoToLLVMPass: instrument, then decide  (instrumentation 0.5 day; follow-up separately planned)

The single biggest serial item (5.31s). Structure verified
(`Passes/EcoToLLVM.cpp` `runOnOperation`): pattern setup →
`lowerAllocGroups(module, runtime)` → `applyFullConversion(module, …)` →
GC/shadow walks → `createGlobalRootInitFunction`.

**Step 1 — sub-phase timers** (ship permanently, cheap): wall-clock each of
the five stages with `std::chrono`, print to `llvm::errs()` when
`getenv("ECO_ECO2LLVM_STATS")` is set (passes have no LoweringStats handle;
env-gating avoids plumbing).

**Step 2 — decision gate** (expected: `applyFullConversion` dominates):
- If `applyFullConversion` ≥70%: write the follow-up design
  (`plans/eco-to-llvm-parallel-conversion.md`) for a two-stage scheme:
  serial prologue (function *signature* conversion + ALL module-level
  artifact creation) + parallel per-`LLVMFuncOp` body conversion. Hard
  prerequisites to establish in that design, not before:
  (a) inventory every module-mutating path reachable from a pattern
  (`grep -n "getOrCreate\|create.*Global\|cacheSymbol" Passes/EcoToLLVMInternal.h Passes/EcoToLLVM*.cpp`),
  (b) a freeze-assert on `EcoRuntime` during the parallel section,
  (c) the func::FuncOp→LLVMFuncOp op-replacement is a module-region
  mutation and MUST stay in the serial stage.
  ⚠ This is the same family as the PARKED `Passes/EcoTailConversions.cpp`
  Heisenbug (garbage `std::function` captures, 176/288 fails, even
  single-threaded) — that root cause must be understood before any custom
  parallel conversion driver ships. Budget it as its own plan.
- If `lowerAllocGroups` or the walks dominate instead: targeted algorithmic
  fix there (cheaper, no parallel driver needed).

---

## Deferred / rejected (do not silently retry)

| Item | Status | Reason |
|---|---|---|
| EcoControlFlowToSCF per-function | **REJECTED (measured)** | tried before; NEUTRAL on 64k tiny fns + `ensureEqualDeclared` symbol insertion (code comment at `EcoControlFlowToSCF.cpp:1108-1114`) |
| Nest stock ConvertControlFlowToLLVM | **BLOCKED** | pass is ModuleOp-pinned in this MLIR (`Conversion/Passes.td:348`); a custom nested clone is EcoTailConversions territory — parked until that Heisenbug is root-caused (worth ~0.9s) |
| MLIR-level pre-translation split | REJECTED | bespoke splitter, weeks of effort for ≤5.6s ceiling |
| Splitting IPSCCP/GlobalOpt per-partition | REJECTED | loses cross-module facts on monomorphized code; recursive-tax regression (prior round, verified) |
| Link/drain overlap | REJECTED | link is 1.14s; <2% ceiling |
| Partition binpack by size | DEFERRED | no straggler skew observed at N=24 |
| `BytecodeDialectInterface` for eco types | REJECTED (measured) | 118 distinct type strings total; dedup already effective |
| Short-symbol mangling (−1.9MB artifact, smaller symtabs) | DEFERRED | real but debuggability tradeoff; needs its own flagged design |

## Order & projection

M1 → M2 → M5 → M3 → M4 → M6 → M7. M1/M2/M5 are independent of each other
and can land in any order; M3/M4 both re-baseline afterwards.

| After | Projected wall (dev self-host) |
|---|---|
| baseline | 28.8s |
| M1 | ~27s |
| M3 | ~24.5–25.5s |
| M4 (if A/Bs pay) | ~23.5–25s |
| M5+M6 | −0.3 to −0.7s + RSS |
| M7 follow-up (if pursued) | ~19–21s |

Frontend side (M2): PhaseMlir and artifact size improvements are tracked
separately via `eco make --stats`.
