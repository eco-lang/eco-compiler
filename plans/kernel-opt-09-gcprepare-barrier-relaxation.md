# Kernel-Opt 09: EcoGCPrepare: gc-leaf kernels stop being safepoints + group barriers

**Status: IMPLEMENTATION-READY v3 — 2026-08-10.** (v1 outline → v2 deepening → v3
adversarial verification pass: every load-bearing anchor re-checked against the tree; two
soundness bugs and one measurement-artefact bug fixed in the Phase-2 sketch; fixture CHECKs
corrected; cross-plan hand-offs to 08/12 made explicit.) Derived from
design_docs/kernel-boundary-reduction.md §8
inventory rows 2–3 (:2004-2005) and §6.F R5; static census
design_docs/kernel-boundary/callsite-census-self-compile.txt (17,005 sites); dynamic census
kernel-census-dynamic-stage7a.txt (3.68B calls, pre-cmp3-stale).

## Files touched

| File | Change |
|---|---|
| `runtime/src/codegen/Passes/EcoMarkGCLeafCalls.cpp` | **NEW** (~70 lines) module-level pass: copies the callee's `eco.gc_leaf` decl fact onto each direct `eco.call` as call-local `eco.callee_gc_leaf` |
| `runtime/src/codegen/Passes.h` | +1 decl in the Stage 2.5 block (:79-91; insert above `createEcoGCPreparePass()`, :85) |
| `runtime/src/codegen/CMakeLists.txt` | add `Passes/EcoMarkGCLeafCalls.cpp` to **BOTH** lists: `set_source_files_properties` (:277-305, file list :278-303, `EcoGCPrepare.cpp` at :287) and `add_mlir_library(EcoPasses …)` (:354-…, `EcoGCPrepare.cpp` at :366) |
| `runtime/src/codegen/EcoPipeline.cpp` | insert `pm.addPass(eco::createEcoMarkGCLeafCallsPass())` immediately before `createEcoGCPreparePass()` (:99) |
| `runtime/src/codegen/Passes/EcoGCPrepare.cpp` | env gates; `isHardMotionBarrier` (the relaxation); `scanBlockForMerges` (census + motion, one code path) wired into `processFunction` between :167 and :170; `isCallSafepoint` gc-leaf arm (:125-140); `runs>=2` tally after `flushGroup()` (:247); census report in `runOnOperation` (:156-163) |
| `runtime/src/codegen/Passes/EcoGCLiveness.h` | shared env-gate helpers so EcoGCPrepare and EcoGCLivenessAudit cannot diverge (the header's stated contract, :3-5) |
| `runtime/src/codegen/Passes/EcoGCLivenessAudit.cpp` | skip stamped gc-leaf calls exactly like musttail (:63-71) |
| `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` | **Phase 2-pre only**: inline-bump lowering for small groups (`lowerOneAllocGroup`, :1851-1986) |
| `test/codegen/gc_alloc_group_baseline.mlir` | **NEW, lands FIRST (Phase 1)**: pins TODAY's group lowering. `grep -rln 'gc_group\|alloc_region\|region_fast' test/` returns **nothing** — the entire allocation-group path is unpinned by fixtures, so Phase 2-pre would be rewriting untested code |
| `test/codegen/gc_group_merge_leaf_call.mlir` | **NEW** positive fixture (merged group → one diamond) |
| `test/codegen/gc_group_merge_bails.mlir` | **NEW** negative controls (dependent operand; unstamped callee) |
| `design_docs/invariants.csv` | HEAP_034 amendment **iff** Phase 2-pre lands (group form gains the inline-bump variant); a CGEN row for the Phase-2 *motion* transform. **No new row for `eco.callee_gc_leaf`** — kernel-opt-07's proposed `KERNEL_FACTS_001` already names "the module-level marker that stamps eco.callee_gc_leaf on eco.call for EcoGCPrepare"; amend that row if its wording drifts, do not add a second |
| `compiler/src/Compiler/Generate/MLIR/Functions.elm` | *not touched here* — kernel-opt-08 owns `eco.gc_leaf` emission at :1995-2008 (`is_kernel` at :1999); 09 only consumes it |

## Goal

Make the per-callee cannot-GC fact visible at the MLIR level so EcoGCPrepare stops treating
gc-leaf kernel calls as (a) allocation-group barriers and (b) call safepoints with full
root-operand lists. This is the MLIR-level half the LLVM-side gc-leaf pilot (kernel-opt-08's
stamped set) never exercised.

**Two corrections to v1 that reshape the plan (both verified in the tree, see Evidence):**
1. `isGroupBarrier` is *not* what splits groups. `processBlock`'s main loop calls
   `flushGroup()` for **every** non-allocation op and then discards `isGroupBarrier`'s
   result (EcoGCPrepare.cpp:240-245) — an `arith.constant` splits a group exactly as a
   kernel call does. Relaxing `isGroupBarrier` alone is a **no-op**. The mechanism that
   merges groups is *op motion* (pull the later allocation up to the run), gated on the
   window being crossable.
2. Merging groups is only a win **after** the group lowering is converted to the HEAP_034
   inline bump. Today a singleton allocation lowers to an inline bump with **no call**
   (`emitInlineAllocWithHeader`, EcoToLLVMInternal.h:846-869), while a group lowers to an
   **out-of-line** `eco_gc_alloc_region_fast` call plus one `eco_init_*_at` call per member
   (EcoToLLVMHeap.cpp:1909-1912, :1929, `emitInitAtPtr` :1642-1748). Merging two singletons
   into a group today *adds* calls. Phase 2-pre exists to fix that, and the census decides
   whether any of it is worth building.

## Evidence

- **Group formation is adjacency-only, not barrier-driven.** `processBlock`'s loop
  (EcoGCPrepare.cpp:221-247): the `else` arm runs `flushGroup()` unconditionally, then
  `if (isGroupBarrier(&op)) { /* empty body */ }`. `isGroupBarrier` (:110-121) has exactly
  one caller (:242) and its value is discarded. Groups therefore consist of **strictly
  adjacent** ops passing `isMayAllocOp` (:40-51) **and** `hasFixedAllocSize` (:56-68), with
  the running-size cap (:231) and the intra-group SSA-dependency guard
  `consumesGroupMemberResult` (:200-208, :230).
- **The lowering hard-requires contiguity.** `lowerAllocGroups` rebuilds each group by
  walking `getNextNode()` `groupSize` times, asserting `next->hasAttr("eco.gc_group_member")`
  (EcoToLLVMHeap.cpp:2007-2013, assert :2009-2010; a second assert on size at :2014-2015).
  The `build` preset compiles `-UNDEBUG` (CMakePresets.json:33-35), so a non-contiguous
  group is a loud assert, not a silent miscompile — but it is still a hard blocker for any
  "merge across an op" design that leaves the ops in place.
- **Group lowering is call-based; singleton lowering is not.** `lowerOneAllocGroup`
  (:1851-1986) splits the block (:1883), emits `eco_gc_alloc_region_fast(totalBytes)`
  (:1909-1912, decl `getOrCreateAllocRegionFast`, EcoToLLVMRuntime.cpp:387-391, gc-leaf),
  a null check + `cf.cond_br` (:1914-1920), per-member `emitInitAtPtr` in fast **and** slow
  blocks (:1929, :1950), `eco_gc_alloc_region_slow` (:1940-1942), and merge-block field
  stores (:1973-1977). `emitInitAtPtr` (:1642-1748) emits a runtime call per member
  (`eco_init_tuple2_at` etc., runtime/src/allocator/RuntimeExports.cpp:1618) and
  **deliberately does not store record/custom fields** (:1748-1750: "Field stores for record
  or custom ops are NOT emitted here — they go in the merge block so they don't need to be
  duplicated across fast/slow paths"); those are `emitFieldStoresForOp` (:1751-…), called
  once per member at :1975 with a `memberResultMap` that rewrites intra-group member results
  to merge-block args. Any inline rewrite of the group form must reproduce **both** steps.
  By contrast the singleton path under
  HEAP_034 emits the `__eco_alloc_inline` marker + one constant header store + inline field
  stores, no calls (cons: EcoToLLVMHeap.cpp:445-456; helpers
  `emitInlineAllocWithHeader` EcoToLLVMInternal.h:846-869, `emitFreshFieldStore` :802-831,
  `value_enc::composeHeader` :298; pinned by test/codegen/inline_alloc_tuple.mlir, which
  invariants.csv HEAP_034 names as its pin).
  `eco_gc_alloc_region_fast` is `Allocator::instance().allocateFast`
  (runtime/src/allocator/RuntimeExports.cpp:1474-1476)
  — a real out-of-line call, and explicitly a *headroom breaker* for capacity hoisting
  (EcoBackend.cpp:1744-1750). **So "two diamonds where one sufficed" (design doc row 3,
  :2005) is backwards on the current tree: the two are two inline bumps; the one is a call.**
- **Safepoint today:** `isCallSafepoint` (:125-140) passes every non-musttail `eco.call`
  (musttail excluded :128-130); Step 4 (:315-351) computes `computeLiveRoots` per safepoint
  and appends the set as extra SSA operands (`CallOp::setGCRoots`, EcoOps.cpp:995-1005).
- **…but those root operands are discarded at lowering.** `CallOpLowering`
  (EcoToLLVMClosures.cpp:2332-…, direct-call arm :2353-2402) splits them off with
  `splitAdaptedRoots` (:36-45, doc comment :34-35 — it reads `eco.gc_roots_count` and
  `take_front`/`drop_front`s the adapted operands) and hands them to `emitSafepointMarker`,
  **which is a no-op** ("RS4GC handles safepoint insertion automatically",
  EcoToLLVMRuntime.cpp:1134-1140); the emitted `func.call` carries
  only `realOperands` (:2401). Ditto `emitAllocWithSafepoint` (:1114-1128) and
  `emitWrapperSafepointMarker` (:1146-1152). **Conclusion: the MLIR root operands on a
  direct kernel call cost MLIR memory and `computeLiveRoots` time, and produce no LLVM IR.**
  The stackmap/spill mass attributed to row 2 (:2004) comes from RS4GC's own liveness at
  statepoints — that is kernel-opt-08's lever, not this one. v1's Expected-impact claim (b)
  is corrected accordingly.
- **`computeLiveRoots` is O(block length) per carrier** (EcoGCLiveness.h:32-66, candidate
  set 3 walks the block prefix at :58-63), so Step 4 is O(n²) per block in call count.
  Skipping the ~2,873/17,005 (16.9%) stampable kernel sites (design-doc row 2 bound, :2004)
  is a real compile-time cut.
- **Skipping a safepoint cannot perturb the OTHER root sets.** `Liveness liveness(func)` is
  built once at :170, *before* Steps 2/4 append any operand; `liveness.isDeadAfter(v, op)`
  answers from that snapshot. So dropping root operands from call X does not shorten or
  lengthen the computed root set of call Y. Together with the "roots are discarded at
  lowering" bullet, this is the whole basis for Phase 3's byte-identity acceptance test.
- **Pass shape (v1 said "per function" — wrong).** `EcoGCPreparePass` is
  `PassWrapper<…, OperationPass<ModuleOp>>` (EcoGCPrepare.cpp:146-147); it walks
  `func::FuncOp`s itself (:159-161). Its mirror consumer `EcoGCLivenessAuditPass` **is**
  nested (`OperationPass<func::FuncOp>`, EcoGCLivenessAudit.cpp:31-32, added via
  `addNestedPass<func::FuncOp>`, EcoPipeline.cpp:101) and therefore must not inspect sibling
  `func.func` decls — which is the concrete reason the contract pins a call-local attr
  rather than a symbol lookup. Both consumers read the same call-local bit.
- **Frequency of every population above is UNMEASURED**, including how often *any* group of
  ≥2 forms today. Phase 1 measures it before a line of transform is written.
- **Attr emission site:** kernel `func.func` decls carry `is_kernel` (BoolAttr) at
  `compiler/src/Compiler/Generate/MLIR/Functions.elm:1999` inside `generateKernelDecl`'s attr
  dict :1995-2008 (the stub is a *definition with a stub body*, :1953-1956 doc comment;
  `KernelFuncOpLowering` turns it into an external `llvm.func`, EcoToLLVMFunc.cpp:26-95).
  `UnitAttr` is fully supported end-to-end — note these three files live under
  `compiler/src/Mlir/`, **not** under `Compiler/Generate/MLIR/`:
  `compiler/src/Mlir/Mlir.elm:64`, `compiler/src/Mlir/Pretty.elm:399` and `:615`,
  `compiler/src/Mlir/Bytecode/AttrType.elm:165` / `:484` / `:917-918` — and it is
  already used for `eco.list_chunks` (Functions.elm:101), `eco.caf_memo` (:503, :681),
  `eco.shadow_roots` (:554).
- **A second `is_kernel` decl is minted in C++.** `EcoCompareCaseRewrite`'s
  `ensureUtilsCmp3Decl` (EcoCompareCaseRewrite.cpp:133-146) inserts
  `Elm_Kernel_Utils_cmp3` with `is_kernel = true` (:143) — but obviously with no
  `eco.gc_leaf`, since nothing in C++ knows the facts table. If the KernelFacts row for
  `Utils.cmp3` is gcLeafEligible, kernel-opt-08 must teach that site to stamp too;
  otherwise 09's marking pass simply never stamps its call sites (whitelist discipline:
  unlisted ⇒ today's behaviour). Flag it to 08; do **not** hand-list the name here.
- **Compile-time pressure is real:** the pipeline already economized here (M4 canonicalizer
  removal, EcoPipeline.cpp:88-96).

## Approach

Seven steps: Phases 0, 1, 2-pre (conditional), 2, 3, 4, 5. Phases 0–1 mutate nothing.
Phases 2-pre/2 are **census-gated** and are the only parts that can move wall. Phase 3 is
expected to be *binary-identical* and buys compile time only.

---

### Phase 0 — the fact channel (inert)

New module-level pass `EcoMarkGCLeafCalls`, mirroring `UndefinedFunction.cpp` (the smallest
module pass that already does symbol-set + `module.walk(CallOp)`, :29-88).

**`runtime/src/codegen/Passes/EcoMarkGCLeafCalls.cpp` (new):**

```cpp
//===- EcoMarkGCLeafCalls.cpp - Stamp call-local gc-leaf facts ------------===//
//
// Copies the per-callee cannot-GC fact from the kernel func.func declaration
// (`eco.gc_leaf`, emitted by the compiler from the kernel-opt-07 facts table)
// onto each DIRECT eco.call as the call-local unit attr `eco.callee_gc_leaf`.
//
// Why a separate module pass: EcoGCPrepare's mirror consumer
// (EcoGCLivenessAudit) is a NESTED func::FuncOp pass and must not inspect
// sibling func.func ops. One module walk here gives both consumers a
// call-local bit they can read without leaving their anchor op.
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "EcoToLLVMInternal.h"   // kernelGcLeafEnabled() — kernel-opt-08's kill switch
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"
#include "llvm/ADT/DenseSet.h"
#include <cstdlib>
#include <fstream>

using namespace mlir;
using namespace ::eco;

namespace {

/// Standalone name source for census runs made BEFORE kernel-opt-08 lands the
/// compiler-side stamp: ECO_GCLEAF_NAMES=<file>, one kernel symbol per line.
/// Never consulted on ordinary builds (the env var is unset).
void loadFallbackNames(MLIRContext *ctx, llvm::DenseSet<StringAttr> &out) {
    const char *path = ::getenv("ECO_GCLEAF_NAMES");
    if (!path || !*path) return;
    std::ifstream in(path);
    for (std::string line; std::getline(in, line); ) {
        while (!line.empty() && (line.back()=='\n'||line.back()=='\r'||line.back()==' '))
            line.pop_back();
        if (!line.empty()) out.insert(StringAttr::get(ctx, line));
    }
}

struct EcoMarkGCLeafCallsPass
    : public PassWrapper<EcoMarkGCLeafCallsPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoMarkGCLeafCallsPass)

    StringRef getArgument() const override { return "eco-mark-gc-leaf-calls"; }
    StringRef getDescription() const override {
        return "Stamp eco.callee_gc_leaf on eco.calls whose callee decl is eco.gc_leaf";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = module.getContext();

        // CROSS-PLAN CONTRACT: kernel-opt-08 pins ECO_KERNEL_GCLEAF=0 as "the
        // backend ignores eco.gc_leaf ENTIRELY without recompiling the .mlir"
        // (08 §Flag & rollback, row 2). If 09 did not honour it, the switch
        // would only half-work — 08 would stop stamping gc-leaf-function while
        // 09 kept de-safepointing and merging. `kernelGcLeafEnabled()` is
        // kernel-opt-08's helper in EcoToLLVMInternal.h; until 08 lands it,
        // read the same env var here with the `inlineAllocEnabled` idiom
        // (EcoToLLVMInternal.h:769-775) and delete the local copy when 08 does.
        if (!eco::kernelGcLeafEnabled()) return;

        // func.func ops are direct children of the module body — iterate the
        // top level, not a recursive walk (UndefinedFunction.cpp:47-49).
        llvm::DenseSet<StringAttr> leaf;
        for (auto funcOp : module.getBody()->getOps<func::FuncOp>())
            if (funcOp->hasAttr("is_kernel") && funcOp->hasAttr("eco.gc_leaf"))
                leaf.insert(funcOp.getSymNameAttr());
        loadFallbackNames(ctx, leaf);
        if (leaf.empty()) return;                 // no stamps => pass is a no-op

        auto unit = UnitAttr::get(ctx);
        uint64_t stamped = 0;
        module.walk([&](CallOp callOp) {
            auto calleeAttr = callOp.getCalleeAttr();
            if (!calleeAttr) return;              // indirect: never stamped
            if (!leaf.contains(calleeAttr.getAttr())) return;
            auto musttail = callOp.getMusttail();
            if (musttail && *musttail) return;    // already a non-safepoint
            callOp->setAttr("eco.callee_gc_leaf", unit);
            ++stamped;
        });

        if (::getenv("ECO_GCLEAF_MARK_REPORT"))
            llvm::errs() << "[gcleaf-mark] " << leaf.size() << " gc-leaf decls, "
                         << stamped << " eco.call sites stamped\n";
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoMarkGCLeafCallsPass() {
    return std::make_unique<EcoMarkGCLeafCallsPass>();
}
```

**Registration checklist (all four, verified against how `createUndefinedFunctionPass` is
wired):**
1. `Passes.h` — declaration in the Stage 2.5 block (above :85), comment naming the attr in
   and the attr out.
2. `CMakeLists.txt` — **two** lists: `set_source_files_properties(...)` (:277-305) and
   `add_mlir_library(EcoPasses ...)` (:354-…). Missing the first only loses a stale-depfile
   guard; missing the second is a link error.
3. `EcoPipeline.cpp` — `pm.addPass(eco::createEcoMarkGCLeafCallsPass());` on the line
   immediately before the existing `pm.addPass(eco::createEcoGCPreparePass());` at :99,
   inside `buildEcoToLLVMPipeline` (:75-130). Correct position: after
   `EcoCompareCaseRewrite` (:69 — `ensureUtilsCmp3Decl` inserts the `Elm_Kernel_Utils_cmp3`
   `is_kernel` decl *and* rewrites call sites) and after `UndefinedFunctionPass` (:72 —
   which **only validates** CGEN_011 and `signalPassFailure()`s on a missing symbol; it
   materialises nothing, despite the stale "Generate external declarations" comment at
   EcoPipeline.cpp:71 — see UndefinedFunction.cpp:39-81). Both run inside
   `buildEcoToEcoPipeline`, which `buildEcoToLLVMPipeline` calls at :77, so by :99 every
   kernel decl exists and every kernel call is final. All four drivers (ecoc.cpp:198,
   EcoRunner.cpp:190, EcoNativeDriver.cpp:107, eco-boot.cpp:379) call
   `buildEcoToLLVMPipeline`, so one insertion covers everything.
4. No `PassRegistration<>` entry: only `EcoToLLVMPass` is registered
   (EcoToLLVM.cpp:623-625); the rest are constructed directly. (`getArgument()` /
   `getDescription()` are still worth writing — every sibling pass has them — but nothing
   reaches them without registration.)

**Acceptance:**

```bash
BK=build/compiler/build-kernel
cp -p $BK/bin/eco-compiler /tmp/eco-compiler.baseline       # before the change
cmake --build build --target eco-boot-native                # rebuild the backend
rm -f $BK/bin/eco-compiler                                  # FORCE Stage 6 to re-run
ECO_GCLEAF_MARK_REPORT=1 ECO_GCLEAF_NAMES=/tmp/gcleaf-seed.txt \
  cmake --build build --target eco-compiler 2>&1 | tee /tmp/mark.txt
grep gcleaf-mark /tmp/mark.txt
cmp /tmp/eco-compiler.baseline $BK/bin/eco-compiler         # must be identical
```

**Why the `rm -f`:** Stage 6 is an `add_custom_command` (compiler/CMakeLists.txt:455-462)
whose only inputs are `eco-compiler.mlir` and the `eco-boot-native` target. Ninja re-runs it
when the backend binary changes, but **not** when only an env var changes — so every
env-varying arm (census, A/B) must delete `$BK/bin/eco-compiler` first or it will silently
measure/print nothing. (Same class as the memory: "harness cache env-blind".)

Expected: a non-zero decl and site count (with `ECO_GCLEAF_NAMES` pointing at the §6.E seed
list if kernel-opt-08 has not landed), and `cmp` silent — the produced `eco-compiler` binary
is **byte-identical** to the pre-Phase-0 binary, because nothing consumes the attr yet.

---

### Phase 1 — census (REQUIRED before any transform)

Implemented **inside** EcoGCPrepare, in the exact function that will later perform the
motion, so census and transform can never diverge.

```cpp
// --- gates (file-static, EcoGCPrepare.cpp, next to GroupLargeObjectThreshold :104-106) ---
static bool censusEnabled() {
    static const bool on = ::getenv("ECO_GCPREPARE_CENSUS") != nullptr;
    return on;
}

// ECO_GCPREPARE_MERGE: unset|0 = off; "free" = 2A only (call-free windows);
// "1" = 2A + 2B (also cross stamped gc-leaf calls). TWO booleans, not one —
// a single `== "1"` test would make `=free` indistinguishable from off and
// the 2A bisect handle would be dead on arrival.
static void mergeModes(bool &freeOn, bool &leafOn) {
    static const std::pair<bool, bool> m = [] {
        const char *e = ::getenv("ECO_GCPREPARE_MERGE");
        if (!e) return std::make_pair(false, false);
        if (::strcmp(e, "1") == 0)    return std::make_pair(true, true);
        if (::strcmp(e, "free") == 0) return std::make_pair(true, false);
        return std::make_pair(false, false);          // "0" and anything else
    }();
    freeOn = m.first; leafOn = m.second;
}
static bool mergeEnabled() { bool f, l; mergeModes(f, l); return f || l; }

// --- counters ---
namespace { struct MergeCensus {
    std::atomic<uint64_t> blocks{0}, groupableAllocs{0}, runs2plus{0}, runObjects{0};
    std::atomic<uint64_t> windows{0}, winNoCall{0}, winLeafOnly{0}, winHardBarrier{0};
    std::atomic<uint64_t> mergeableFree{0}, mergeableLeaf{0};
    std::atomic<uint64_t> blockedDeps{0}, blockedSize{0};
    std::atomic<uint64_t> safepoints{0}, safepointRoots{0};
    std::atomic<uint64_t> leafSafepoints{0}, leafSafepointRoots{0};
}; }
static MergeCensus gCensus;   // module pass runs serially; atomics are belt-and-braces
```

`scanBlockForMerges(Block &block, bool apply)` is the single walk (sketch in Phase 2). In
census mode (`apply=false`) it classifies and counts; in transform mode it also moves. Step 4
(:328-351) gains two counter bumps: `safepoints`/`safepointRoots` for every carrier, plus
`leafSafepoints`/`leafSafepointRoots` when `op->hasAttr("eco.callee_gc_leaf")`.

**The classification must NOT consult the merge gates.** The census runs with
`ECO_GCPREPARE_MERGE` unset; if the gc-leaf exception were gated on `mergeLeafEnabled()`
(as a naive `isMotionBarrier` would be), every stamped call would classify as a hard
barrier and `winLeafOnly` / `mergeableLeaf` would be **structurally zero** — the census that
decides this entire plan would measure nothing and read as "no opportunity". Hence the
Phase-2 sketch splits `isHardMotionBarrier` (classification, leaf exception always on) from
the *apply* decision (gated).

Report at the end of `runOnOperation` (after the `module.walk` at :159-161), mirroring the
`[gcfree]` one-liner idiom (EcoBackend.cpp:1719-1725):

```
[gcprepare-census] blocks=… groupable=… runs>=2=… runObjects=…
[gcprepare-census] windows=… noCall=… leafOnly=… hardBarrier=… mergeableFree=… mergeableLeaf=… blockedDeps=… blockedSize=…
[gcprepare-census] safepoints=… roots=… leafSafepoints=… leafRoots=…
```

**Run it (workload = the compiler lowering its own 12 MB module; the backend runs during the
`eco-compiler` build, so this is the census target — NOT `--target full`, which deletes the
`.mlir`, memory: capacity-check-hoisting traps):**

```bash
BK=build/compiler/build-kernel
cmake --build build --target eco-boot-native      # backend carries the counters
rm -f $BK/bin/eco-compiler                        # force Stage 6 (see Phase 0 acceptance)
ECO_GCPREPARE_CENSUS=1 ECO_GCLEAF_MARK_REPORT=1 ECO_GCLEAF_NAMES=/tmp/gcleaf-seed.txt \
  cmake --build build --target eco-compiler 2>&1 | tee /tmp/gcprepare_census.txt
grep -E '\[gcprepare-census\]|\[gcleaf-mark\]' /tmp/gcprepare_census.txt
```

Run it **once** and grep the tee'd file (repo rule). The `runs>=2` / `runObjects` /
`safepoints` lines are meaningful with `ECO_GCLEAF_NAMES` empty or absent — only the
`*Leaf*` columns need the seed list, so a first pass can precede any of kernel-opt-07/08.

**Go/no-go, decided here and recorded in this file:**

| Reading | Branch |
|---|---|
| `runs>=2` ≈ 0 | The grouping mechanism is effectively dead on today's IR. **Drop Phases 2/2-pre entirely**; ship Phase 3 only and record the number. Also file the finding against design-doc row 3. |
| `runs>=2` large (say ≥ 5,000) | Phase 2-pre (inline-bump group lowering) is a **standalone** win independent of the kernel-facts spine — every existing group is paying an out-of-line region call plus per-member init calls today. Do 2-pre first, measure, then decide on 2. |
| `mergeableFree` ≥ 3 × `mergeableLeaf` | Build Phase 2A first (motion across call-free windows). It needs **no** kernel facts at all — a cheaper, larger, fact-independent win; 2B then rides on the same machinery. |
| `mergeableLeaf` ≥ 2,000 (≥ ~5% of the 38,603 HEAP_034 bump diamonds) **and** 2-pre landed | Build Phase 2B (motion across stamped gc-leaf calls). |
| `mergeableLeaf` in [500, 2000) **and** 2-pre measured a wall win | Build 2B anyway — the marginal cost over an already-landed 2A is one predicate; but require the 2B-only wall A/B to clear noise on its own before flipping its default. |
| `mergeableLeaf` < 500 **and** `mergeableFree` < 500 | Descope Phase 2 entirely. Ship Phase 3 (compile-time) and stop. This is the expected-honest outcome given ×4 prior collapses at admissibility gates. |
| `blockedDeps` dominates `mergeable*` | The windows are crossable but the dependencies are real; motion cannot help. Record it and descope — do **not** attempt operand-chasing/reassociation to unblock them, that is a different (and much larger) plan. |

**Acceptance:** counters printed; `eco-compiler` byte-identical to baseline (census mutates
nothing); the decision written into this file with the numbers.

---

### Phase 2-pre — inline-bump lowering for small groups (conditional; the enabling change)

Without this, merging allocations is a pessimization (see Evidence). Gate:
`ECO_GCPREPARE_GROUP_INLINE=1` (default off).

In `lowerOneAllocGroup` (EcoToLLVMHeap.cpp:1851-1986), when
`inlineAllocEnabled() && groupInlineEnabled() && totalBytes <= 4096 && (totalBytes % 8)==0`
(HEAP_034 clause (a)), replace the whole fast/slow/merge CFG with straight-line code:

```cpp
    // HEAP_034 form 1 applied to a GROUP: one marker for the whole region,
    // then per-member header word + fields, all straight-line. No safepoint
    // can intervene (members are adjacent by construction), so no zero-init
    // and no root list are needed — same contract as the singleton path.
    // NB: no block splitting, no merge-block args, no cf.cond_br — everything
    // is emitted in place at `leader`, so lowerAllocGroups' caller-side
    // assumptions (it only iterates a pre-collected `allGroups`, :1989-2026)
    // are untouched.
    if (useInlineGroupForm(totalBytes)) {
        OpBuilder b(leader);
        auto ecoValueTy = eco::ValueType::get(ctx);
        Value base = emitInlineAllocRegion(b, loc, runtime, totalBytes); // marker only

        // Step 1: per-member header/meta words + the init-time fields that
        // emitInitAtPtr would have written (cons head/tail, tuple slots, ...).
        SmallVector<Value, 8> hptrs;
        for (size_t i = 0; i < groupSize; ++i) {
            Value objPtr = gepBytes(b, loc, base, offsets[i]);            // NEW helper
            hptrs.push_back(emitInitAtPtrInline(b, loc, group[i], objPtr)); // NEW helper
        }

        // Step 2: the record/custom field stores emitInitAtPtr does NOT do
        // (EcoToLLVMHeap.cpp:1748-1750). The call form defers these to the
        // merge block (:1972-1977); the inline form has no merge block, so
        // they land here — AFTER every member's header exists, so a member
        // stored into a sibling's field is already a valid object.
        // memberResultMap replaces the merge-block-arg mapping: it maps each
        // group member's ORIGINAL !eco.value result to its new hptr, which is
        // exactly what emitFieldStoresForOp's `it->second` expects.
        llvm::DenseMap<Value, Value> memberResultMap;
        for (size_t i = 0; i < groupSize; ++i)
            memberResultMap[group[i]->getResult(0)] = hptrs[i];
        for (size_t i = 0; i < groupSize; ++i)
            emitFieldStoresForOp(b, loc, group[i], hptrs[i],
                                 memberResultMap, runtime);   // existing, :1751

        // Step 3: replace results, then erase back-to-front (mirrors :1979-1985).
        for (size_t i = 0; i < groupSize; ++i)
            group[i]->getResult(0).replaceAllUsesWith(
                b.create<UnrealizedConversionCastOp>(loc, ecoValueTy, hptrs[i])
                    .getResult(0));
        for (auto it = group.rbegin(); it != group.rend(); ++it) (*it)->erase();
        return;
    }
```

Three new helpers next to the existing ones:
- `gepBytes(b, loc, base, byteOffset)` — the two-line `LLVM::ConstantOp` + `LLVM::GEPOp`
  pair the call form already open-codes at :1926-1928 / :1947-1949, factored out so both
  forms use one definition.
- `emitInlineAllocRegion` — `emitInlineAllocWithHeader` (EcoToLLVMInternal.h:846-869) minus
  the header store (the marker call + size constant only; keep the AS1 return type).
- `emitInitAtPtrInline(b, loc, op, objPtr)` — the inline twin of `emitInitAtPtr`
  (:1642-1748): same per-class `dyn_cast` chain, but each arm composes the header word with
  `value_enc::composeHeader` (EcoToLLVMInternal.h:298) + `emitInlineAllocMetaWord` (:873-…)
  where the class has a second constant word, and stores fields with `emitFreshFieldStore`
  (EcoToLLVMInternal.h:802-831) instead of calling `eco_init_*_at`. It does **not** take
  `runtime` — unlike `emitInitAtPtr` it creates no runtime decls. Start with the classes
  the Phase-1 census says dominate `runObjects` (expect Cons / Tuple2 / Custom per the
  live-heap composition memory) and fall through to the existing call-based path for the
  rest. A member-by-member mix is NOT legal (the call form's members live in fast/slow
  blocks that the inline form does not create), so `useInlineGroupForm` must gate the whole
  group on "every member has an inline arm" **and** the size clause.

Per-class arms already exist to copy verbatim from the singleton lowerings: cons at
EcoToLLVMHeap.cpp:445-456, tuple2/tuple3 and record/custom in the same file's
`inlineAllocEnabled()` branches. `emitInitAtPtrInline` is those bodies with the
`emitInlineAllocWithHeader(...)` call replaced by "store the composed header at `objPtr`".

**Traps:** `GroupLargeObjectThreshold` (32 KiB, :106) must be tightened to 4096 for
inline-form groups — either a second cap in the grouping walk or a fallback to the call form
in the lowering (prefer the fallback: grouping stays untouched). REP_LLVM_002: boxed field
stores must keep the `eco.boxed_slot` marker — `emitFreshFieldStore` sets it (:829-830); do
not hand-roll the store.

**Prerequisite (do this before touching `lowerOneAllocGroup`):** land
`test/codegen/gc_alloc_group_baseline.mlir` pinning TODAY's call-based group form.
`grep -rln 'gc_group\|alloc_region\|region_fast' test/` returns **nothing** — there is no
fixture anywhere covering the allocation-group path, so this rewrite would otherwise be
unpinned in both directions. Shape: two adjacent `eco.construct.tuple2`s in one block at
`-emit=mlir-llvm`, with `CHECK: llvm.call @eco_gc_alloc_region_fast`,
`CHECK: llvm.call @eco_init_tuple2_at`, `CHECK: llvm.mlir.constant(48 : i64)`. It flips to
the inline expectations in the same commit that flips `ECO_GCPREPARE_GROUP_INLINE`.

**Acceptance:** with `ECO_GCPREPARE_GROUP_INLINE=1` and no motion enabled, existing groups
lower with zero `eco_gc_alloc_region_fast` / `eco_init_*_at` calls; full E2E + heap-validate
green; wall A/B recorded (this is the arm most likely to move wall in the whole plan, because
it deletes real per-object call overhead — the "deleted per-op work" class, not the
metadata class).

---

### Phase 2 — the relaxation: motion across crossable windows

Two knobs on one mechanism: 2A (windows containing no call-like op) and 2B (windows whose
only call-like ops are stamped `eco.callee_gc_leaf`). `ECO_GCPREPARE_MERGE=1` enables both;
`ECO_GCPREPARE_MERGE=free` enables only 2A (bisect handle).

**The relaxation predicate — this is where "gc-leaf kernels stop being group barriers"
literally lives**, expressed against the existing `isGroupBarrier` (:110-121), which stays
unchanged:

```cpp
/// A window op the later allocation may NOT be moved across — the
/// CLASSIFICATION predicate, deliberately independent of every env gate so the
/// Phase-1 census can count leaf-only windows with the transform switched off.
/// The gc-leaf arm IS the relaxation: a stamped call cannot trigger GC, so a
/// merged group can never expose a partially-initialised object to a collector.
static bool isHardMotionBarrier(Operation *op) {
    if (op->getNumRegions() > 0) return true;          // scf.if/while: never step over
    if (isa<eco::PapCreateGroupOp>(op)) return true;   // NOT covered by isGroupBarrier
                                                       // (:110-121) though it IS a
                                                       // safepoint (:137-138)
    if (auto c = dyn_cast<eco::CallOp>(op))
        if (c->hasAttr("eco.callee_gc_leaf"))
            return false;                              // <<< THE RELAXATION
    return isGroupBarrier(op);                         // unchanged, still :110-121
}
```

Note the ordering: the `PapCreateGroupOp` test must precede the `CallOp` test only if the
two could ever alias — they cannot (`PapCreateGroupOp` is its own op class) — but keeping
region-bearing ops first means a hypothetical future region-carrying call is rejected
before the attr is consulted, which is the safe direction.

**The single walk (census + transform):**

```cpp
/// Pull groupable allocations up to the tail of the preceding run when the
/// intervening window is crossable. Restores ADJACENCY, so the existing
/// grouping (:221-247) and the existing contiguity-dependent lowering
/// (EcoToLLVMHeap.cpp:2007-2015) merge them with no downstream change.
/// Must run BEFORE Liveness is constructed — Liveness caches per-block order.
static unsigned scanBlockForMerges(Block &block, bool apply) {
    bool mergeFreeOn, mergeLeafOn;
    mergeModes(mergeFreeOn, mergeLeafOn);

    unsigned moved = 0;
    Operation *runTail = nullptr;                    // last op of the open run
    int64_t runningSize = 0;
    llvm::SmallPtrSet<Operation *, 16> window;       // ops physically between
                                                     // runTail and the cursor
    llvm::SmallPtrSet<Operation *, 8>  runSet;       // ops in the open run
    bool winSafe = true, winHasCall = false, winNonEmpty = false;

    auto dependsOn = [](Operation *op, const llvm::SmallPtrSetImpl<Operation *> &s) {
        for (Value v : op->getOperands())
            if (Operation *d = v.getDefiningOp())
                if (s.contains(d)) return true;
        return false;
    };

    // SNAPSHOT the block first. `llvm::make_early_inc_range` is NOT enough:
    // moveAfter() relocates the op to a position we have already passed, which
    // drags every window op AFTER the cursor, so the forward iterator would
    // then SKIP exactly the ops we just crossed. Skipping them silently drops
    // them from `window`, and the next candidate's dependsOn() check would miss
    // a dependency on a crossed call's result -> we would hoist an allocation
    // above its own operand's definition. Concretely, on
    //     A1 ; %n = <leaf call> ; A2 ; w ; A3(%n)
    // the naive version moves A2 above the call, resumes at `w` (the call is
    // skipped), then judges A3 against window={w} and moves it above the call
    // too -> `%n` used before defined. Snapshot + "retain window on a
    // successful move" (below) is the fix.
    SmallVector<Operation *, 64> ops;
    ops.reserve(block.getOperations().size());
    for (Operation &o : block) ops.push_back(&o);

    for (Operation *op : ops) {
        if (isMayAllocOp(op) && hasFixedAllocSize(op)) {
            int64_t sz = getFixedAllocSizeForGrouping(op);
            bool adjacent = runTail && op->getPrevNode() == runTail;
            bool didMove = false;
            if (runTail && !adjacent && winNonEmpty) {
                gCensus.windows++;
                if (!winSafe)         gCensus.winHardBarrier++;
                else if (winHasCall)  gCensus.winLeafOnly++;
                else                  gCensus.winNoCall++;
                bool depsOk = !dependsOn(op, window) && !dependsOn(op, runSet);
                bool sizeOk = runningSize + sz < GroupLargeObjectThreshold;
                if (!winSafe)      { /* hard barrier: nothing to do */ }
                else if (!depsOk)  gCensus.blockedDeps++;
                else if (!sizeOk)  gCensus.blockedSize++;
                else {
                    (winHasCall ? gCensus.mergeableLeaf : gCensus.mergeableFree)++;
                    // The APPLY gate — and the only place a gate is read.
                    bool gateOk = winHasCall ? mergeLeafOn : mergeFreeOn;
                    if (apply && gateOk) {
                        op->moveAfter(runTail);
                        ++moved; adjacent = true; didMove = true;
                    }
                }
            }
            if (adjacent) runningSize += sz;
            else { runningSize = sz; runSet.clear(); }
            runTail = op; runSet.insert(op);
            if (!didMove) {
                // op stayed put: everything in `window` is now BEFORE the new
                // runTail, so it can never sit between runTail and a later
                // candidate. Start a fresh window.
                window.clear(); winSafe = true; winHasCall = false;
                winNonEmpty = false;
            }
            // If we DID move, the crossed ops are now AFTER op (== the new
            // runTail) and therefore still inside the window of the next
            // candidate. Keep window/winSafe/winHasCall/winNonEmpty as they
            // are: that is what makes the dependsOn() check above sound for
            // the second and later merges in one run.
            gCensus.groupableAllocs++;
            continue;
        }
        window.insert(op); winNonEmpty = true;
        if (op->hasTrait<OpTrait::IsTerminator>() || isa<eco::CallOp, func::CallOp,
                eco::PapCreateOp, eco::PapExtendOp, eco::PapCreateGroupOp>(op))
            winHasCall = true;                       // "call-like was crossed"
        if (isHardMotionBarrier(op)) winSafe = false;
    }
    return moved;
}
```

`gCensus.runs2plus` / `runObjects` are derived at the end of `processBlock` from the
`groups` vector that Step 1 already builds (`for (auto &g : groups) if (g.size() >= 2) {
++runs2plus; runObjects += g.size(); }`, inserted after `flushGroup()` at :247) — that way
the "how many groups of ≥2 exist" number is read off the *real* grouping, not a
reimplementation of it. `gCensus.blocks` bumps once per `processBlock` entry.

Wire it into `processFunction` (:166-183), in the gap between the `if (func.isExternal())
return;` guard (:167) and `Liveness liveness(func);` (:170) — i.e. the motion must land on
lines that today hold only the blank line and the comment at :168-169:

```cpp
    void processFunction(func::FuncOp func) {
        if (func.isExternal()) return;                  // existing :167

        // kernel-opt-09 Phase 1/2. MUST precede the Liveness construction:
        // Liveness caches per-block orderings and live-in/out sets, and any op
        // motion after it silently produces stale root sets in the UNDER-rooting
        // direction (the unsafe one — EcoPipeline.cpp:88-96 spells out the
        // asymmetry). Same `func.walk([&](Block *block))` shape as :180-182,
        // so nested scf regions are covered too.
        if (censusEnabled() || mergeEnabled())
            func.walk([&](Block *block) {
                scanBlockForMerges(*block, /*apply=*/mergeEnabled());
            });

        Liveness liveness(func);                        // existing :170
```

New includes for EcoGCPrepare.cpp: `<atomic>`, `<cstdlib>`, `<cstring>`,
`"llvm/ADT/SmallPtrSet.h"`, `"llvm/ADT/SmallVector.h"` (the file today includes only the
MLIR headers at :14-27 plus `llvm/Support/Debug.h`).

**Why this is sound (state it in the code comment):**
- *Dominance.* Every value the moved op consumes is either (a) defined outside this block or
  before `runTail` — unaffected by the move; (b) defined by an op in the open run — caught by
  `dependsOn(op, runSet)`; or (c) defined by an op in the window — caught by
  `dependsOn(op, window)`, which is exhaustive **because `window` retains the ops crossed by
  an earlier successful move** (see the snapshot comment). Case (b) subsumes the existing
  `consumesGroupMemberResult` guard (:200-208). A one-level operand check suffices: there is
  no fourth case, so transitivity is not needed.
- *Partially-initialised objects.* Group lowering initialises members in the fast/slow blocks
  and stores record/custom fields at the top of the merge block (:1955-1977). Merging across
  a call that can GC would let a collector observe a member between its region reservation
  and its field stores. A stamped gc-leaf callee cannot GC, so the window is safe. (For 2A
  the window contains no call at all.)
- *Rooting.* Motion happens before `Liveness` is built, so Step 2 (:249-305) and Step 4
  (:315-351) compute root sets over the final order — no stale root sets by construction.
- *Order of effects.* Only allocations move, and only earlier. An allocation's observable
  effects are heap bump and (slow path) a minor GC; neither is Elm-observable, and the
  moved value's later uses are unchanged.
- *Adjacency preserved.* Because we move ops rather than admit non-adjacent group members,
  `lowerAllocGroups`' contiguity walk and both asserts (:2007-2015) keep holding untouched.
  **Rejected alternative (Option A):** teach grouping to accept non-adjacent members. It
  requires group-id/index attrs, a rewritten reconstruction in `lowerAllocGroups`, and —
  fatally — `emitInitAtPtr` consumes each member's operands in the *fast/slow* blocks
  (:1929/:1950) which precede the intervening op, so any member operand defined in the window
  would break dominance. Option B (motion) needs none of that.

**Acceptance:** `ECO_GCPREPARE_MERGE=1` census counters show `mergeableLeaf`/`mergeableFree`
moves actually applied (`runs>=2` and `runObjects` rise by the expected amount on a re-run);
`ECO_LOWERING_VALIDATION` build green; heap-validate suite green; E2E green.

---

### Phase 3 — safepoint relaxation (expected binary-identical)

Shared gate in `EcoGCLiveness.h`, inside its existing `namespace eco { … }` (:19-68) — the
header states its own contract at :3-5: "These are the authoritative definitions; neither
pass should have local copies." It currently includes no C headers, so add `#include
<cstdlib>` next to the existing includes (:12-17):

```cpp
/// ECO_GCPREPARE_LEAF_SAFEPOINT=1 — stop treating eco.calls stamped
/// `eco.callee_gc_leaf` as call safepoints. Default OFF (v1).
/// Lives HERE, not in either .cpp: EcoGCPrepare's isCallSafepoint and
/// EcoGCLivenessAudit's skip list must agree bit-for-bit or validator
/// builds fail with false positives (see Traps).
inline bool gcLeafSafepointRelaxed() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_GCPREPARE_LEAF_SAFEPOINT");
        return e && e[0] == '1' && e[1] == '\0';
    }();
    return on;
}
```

`isCallSafepoint` (EcoGCPrepare.cpp:125-140) gains one arm after the musttail arm:

```cpp
    if (auto callOp = dyn_cast<eco::CallOp>(op)) {
        auto musttail = callOp.getMusttail();
        if (musttail && *musttail) return false;
        // gc-leaf callee: cannot trigger GC ⇒ no independent root set. Read the
        // CALL-LOCAL attr stamped by EcoMarkGCLeafCalls; never look up the
        // callee decl (the audit twin is a nested per-function pass).
        if (eco::gcLeafSafepointRelaxed() && op->hasAttr("eco.callee_gc_leaf"))
            return false;
        return true;
    }
```

**Ordering hazard with kernel-opt-12 (whichever lands second owns the fix):** 12 strips its
`eco.cse_safe` attr inside Step 4's loop (its Files-touched cites EcoGCPrepare.cpp:328-330),
but that loop's first statement is `if (!isCallSafepoint(&op)) continue;` (:329). Once this
arm lands, a call that is both `eco.cse_safe` and `eco.callee_gc_leaf` short-circuits before
the strip and 12's "must not survive EcoGCPrepare" verifier fires. Fix by hoisting the strip
above the `isCallSafepoint` guard (it is unconditional cleanup, not root computation).

`EcoGCLivenessAudit.cpp` gains the parity skip immediately after the musttail skip (:63-71):

```cpp
            // Skip stamped gc-leaf calls — EcoGCPrepare's isCallSafepoint
            // excludes them under ECO_GCPREPARE_LEAF_SAFEPOINT. Same reason as
            // musttail: no safepoint, so nothing to root.
            if (eco::gcLeafSafepointRelaxed() && op->hasAttr("eco.callee_gc_leaf"))
                return;
```

**Layered defense with kernel-opt-08 — the exact division of labour (verified):**
`isCallSafepoint` controls **only** the MLIR-side root-operand list (Step 4 → `setGCRoots`,
EcoOps.cpp:995-1005, which also writes `eco.gc_roots_count`). Those operands are split off
and **dropped** at lowering (`splitAdaptedRoots` reads that same attr, then no-op
`emitSafepointMarker`), so removing them changes no LLVM IR.
RS4GC — LLVM's own `RewriteStatepointsForGC` — controls the statepoint, the spill/reload and
the stackmap entry, and skips a call site whose *callee declaration* carries
`gc-leaf-function`; that stamp is kernel-opt-08's. Eco's own three in-tree consumers of the
same predicate are `llvm::callsGCLeafFunction(cb, TLI)` at EcoBackend.cpp:1658 (the CGEN_072
gc-free fixpoint — its comment at :1620-1622 states it is "literally the one RS4GC consults
per call site"), :1880, and :2153 (capacity-hoisting run breaking). **The two mechanisms are
disjoint: MLIR operand lists on one side, LLVM statepoints/stackmaps on the other. Either
alone is sound.** 08 removes real machine-level cost; 09 Phase 3 removes MLIR-level analysis
cost only. Say so plainly rather than double-counting the stackmap win — and note that
08 landing *first* is what makes 09 Phase 3 free to be a pure compile-time change.

**Acceptance (strong, and the reason this phase is cheap to trust):** with
`ECO_GCPREPARE_LEAF_SAFEPOINT=1` and merge OFF, the produced `eco-compiler` binary must be
**byte-identical** to the merge-OFF/relax-OFF baseline:

```bash
BK=build/compiler/build-kernel
rm -f $BK/bin/eco-compiler && cmake --build build --target eco-compiler
cp -p $BK/bin/eco-compiler /tmp/relax-off
rm -f $BK/bin/eco-compiler
ECO_GCPREPARE_LEAF_SAFEPOINT=1 cmake --build build --target eco-compiler
cmp /tmp/relax-off $BK/bin/eco-compiler        # MUST be silent
```

If it is not, a consumer of the root operands exists that this analysis missed — stop and
find it before proceeding (start from the other `getGCRoots()` readers: `EcoOps.cpp:989`,
`lowerOneAllocGroup`'s leader read at EcoToLLVMHeap.cpp:1871-1876, and the audit's :102).
Record the MLIR-phase time delta (`/usr/bin/time -v`, and the Stage-6 line of the build log).

---

### Phase 4 — fixtures and the default flip

The codegen harness runs `ecoc "<file>" -emit=<mode>` and nothing else
(`runSubprocessTest`, CodegenIsolatedTest.hpp:237-242; `getEcocPath` resolves
`build/runtime/src/codegen/ecoc`, :135-151) — **no per-test env**, so fixtures can only pin
behaviour that is default-on. Directive support is `CHECK` / `CHECK-NOT` / `-DAG` / `-LABEL`
/ `-SAME` / `-NEXT` only, and **an unrecognised `CHECK-*` variant is a hard parse error**
(test/CheckPatterns.hpp:4-29) — so no `CHECK-COUNT`; "exactly one diamond" must be expressed
as presence + absence of the alternative, not as a count. `CHECK-NOT` is whole-output
(CheckPatterns.hpp:8), hence the positive/negative split into two files.

Land the fixtures in the same commit that flips the defaults; during Phases 2–3 verify by
hand:

```bash
ECO_GCPREPARE_MERGE=1 ECO_GCPREPARE_GROUP_INLINE=1 \
  build/runtime/src/codegen/ecoc test/codegen/gc_group_merge_leaf_call.mlir \
  -emit=mlir-llvm 2>&1 | grep -cE '__eco_alloc_inline|eco_gc_alloc_region_fast'
```

**`test/codegen/gc_group_merge_leaf_call.mlir` (positive).** Syntax verified against
`caf_memo_basic.mlir:12-30` (private `func.func` + generic-form `"eco.call"() {callee = @…}`
+ `eco.return`, at `-emit=mlir-llvm`), `inline_alloc_tuple.mlir:21-23` (tuple2 construct /
project; `unboxed_bitmap` 2-bit kinds Int=01 ⇒ `(i64,i64)` = 0b0101 = 5) and
`compare_case_rewrite_structural.mlir:13` (the ONE in-tree `is_kernel` decl — note it is
`-emit=mlir-eco`, so an `is_kernel` decl at `-emit=mlir-llvm` is untried; it is handled by
`KernelFuncOpLowering`, EcoToLLVMFunc.cpp:26-95, which turns the stub into an external
`llvm.func`). Fixtures with no `@main` at `-emit=mlir-llvm` already exist
(`value_cons.mlir`, `to_heap_custom_no_fca.mlir`).

```mlir
// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// kernel-opt-09 Phase 2B: a gc-leaf-stamped kernel call between two
// fixed-size constructions is not a motion barrier — the second construct is
// pulled up to the first, the pair forms ONE allocation group, and the group
// lowers to ONE capacity diamond (Phase 2-pre: one inline bump).
module {
  func.func private @Elm_Kernel_String_length(%s: !eco.value) -> i64
      attributes {is_kernel = true, eco.gc_leaf}

  func.func private @merge_across_leaf(%s: !eco.value, %a: i64, %b: i64) -> i64 {
    %t1 = eco.construct.tuple2 %a, %b {unboxed_bitmap = 5} : i64, i64 -> !eco.value
    %n  = "eco.call"(%s) {callee = @Elm_Kernel_String_length} : (!eco.value) -> i64
    %t2 = eco.construct.tuple2 %b, %a {unboxed_bitmap = 5} : i64, i64 -> !eco.value
    %p1 = eco.project.tuple2 %t1[0] : !eco.value -> i64
    %p2 = eco.project.tuple2 %t2[1] : !eco.value -> i64
    %s1 = arith.addi %p1, %p2 : i64
    %s2 = arith.addi %s1, %n : i64
    eco.return %s2 : i64
  }
}
// ONE region of 24+24 = 48 bytes for the merged pair, via ONE inline bump.
// CHECK: llvm.mlir.constant(48 : i64)
// CHECK: llvm.call @__eco_alloc_inline
// "ONE diamond" is asserted as the ABSENCE of the alternatives, not a count
// (the harness has no CHECK-COUNT):
// CHECK-NOT: eco_gc_alloc_region_fast
// CHECK-NOT: eco_init_tuple2_at
// CHECK-NOT: llvm.call @eco_alloc_tuple2_uninit
```

**Do NOT add `CHECK-NOT: llvm.mlir.constant(24 : i64)`** (v2 had it): the merged group
addresses its second member with a GEP at byte offset 24, so that exact constant is emitted
by the inline form — the check would fail by construction. The size-24 singleton form is
excluded instead by the `eco_alloc_tuple2_uninit` / `__eco_alloc_inline`-count reasoning
above plus the negative file.

(If Phase 2-pre is descoped, the positive CHECKs become
`CHECK: llvm.call @eco_gc_alloc_region_fast` + `CHECK: llvm.call @eco_init_tuple2_at` +
`CHECK-NOT: __eco_alloc_inline` — but that variant should only be written if the census went
that way, since it pins a slower lowering.)

**`test/codegen/gc_group_merge_bails.mlir` (negative controls; separate file because this
harness evaluates `CHECK-NOT` against the WHOLE output, compare_case_rewrite_structural.mlir:7-8):**
two functions — (a) the second construct consumes the call result (`%t2` takes `%n` as a
field, so `dependsOn(op, window)` fires), (b) the callee decl carries `is_kernel` but **not**
`eco.gc_leaf`, so `EcoMarkGCLeafCalls` never stamps it and `isHardMotionBarrier` falls
through to `isGroupBarrier` — with `CHECK-NOT: eco_gc_alloc_region_fast` and
`CHECK-NOT: llvm.mlir.constant(48 : i64)` (both tuples stay singletons at 24 bytes each).

**Flip:** each gate flips independently, in this order, each with its own full gate battery:
2-pre → 3 → 2A → 2B. Flip = invert the env test (`!(e && e[0]=='0')`, the
`inlineAllocEnabled` idiom, EcoToLLVMInternal.h:769-775), keeping `=0` as the kill switch.

---

### Phase 5 — measurement and re-census

Re-run the Phase-1 census with each gate on and record, in this file: `runs>=2`, `runObjects`,
`windows` by class, applied moves, `safepoints`/`roots` before/after, plus:
`.text` and `.llvm_stackmaps` section sizes (`llvm-size -A build/compiler/build-kernel/bin/eco-compiler`),
MLIR-phase time, and a cold Stage-7a wall A/B **with major-GC counts** (the GC-trigger
lottery — memory: LSS exploitation lessons). Wall recipe, run from `/work`
(benchmarks/runtime-calls.md, "Commands" from :60; Phase 1 build block :62-77, Phase 2
workload block :79-96): rebuild `eco-compiler` per arm with the env set at the **build**
step — the transform lives in `eco-boot-native`, which is what compiles `eco-compiler.mlir`
into the measured binary at Stage 6, so it is the *build* env that matters and the workload
env is irrelevant to this plan. Per arm: `rm -f "$BK/bin/eco-compiler"` (Stage 6 is
env-blind to ninja — see Phase 0 acceptance), build with the arm's env, `cp -p` the binary
to a flavour-labelled name, then `rm -rf "$BK/eco-stuff"` and run the labelled binary
self-compiling per the doc's Phase 2 block. Interleave 2×2, `cmp` the two `bin/out.mlir`
outputs (byte-identical ⇒ the arm is codegen-neutral, which Phase 3 requires and Phases
2/2-pre will violate legitimately).

## Flag & rollback

| Flag | Default (v1) | Effect | Kill switch |
|---|---|---|---|
| `ECO_GCPREPARE_CENSUS` | unset = off | counters only, mutates nothing | unset |
| `ECO_GCLEAF_NAMES=<file>` | unset | standalone gc-leaf name list for pre-08 census runs | unset |
| `ECO_GCLEAF_MARK_REPORT` | unset = quiet | one-line stamp report | unset |
| `ECO_GCPREPARE_GROUP_INLINE` | `0` (off) | Phase 2-pre inline-bump group lowering | `=0` |
| `ECO_GCPREPARE_MERGE` | unset/`0` (off) | Phase 2 motion; `1` = 2A+2B, `free` = 2A only | `=0` |
| `ECO_GCPREPARE_LEAF_SAFEPOINT` | `0` (off) | Phase 3 safepoint relaxation | `=0` |
| `ECO_KERNEL_GCLEAF` *(owned by kernel-opt-08)* | on | `=0` makes the **whole** backend ignore `eco.gc_leaf`; 09's marking pass honours it, so it is the one switch that disables 09's transforms *and* 08's stamp together without recompiling the `.mlir` | `=0` |

The marking pass itself is **inert** (attr-only) and needs no flag of its own: with
`ECO_KERNEL_GCLEAF=0`, or with no `eco.gc_leaf` decls and no `ECO_GCLEAF_NAMES`, it returns
immediately. Rollback of any phase is its env `=0`; full revert is four independent diffs
plus, for the pass, the four registration points listed in Phase 0. The compiler-side
`eco.gc_leaf` emission belongs to kernel-opt-08 and rolls back with that plan's own Config
flag (`EcoConfig.kernelGcLeaf` / `ECO_KERNEL_GCLEAF_EMIT`).

## Traps & risks

- **The v1 mechanism does not exist.** `isGroupBarrier`'s result is discarded (:242-245);
  relaxing it changes nothing. Anyone implementing v1 literally would ship a no-op and
  measure "flat" for the wrong reason. The transform is op motion.
- **Merging is a pessimization without Phase 2-pre.** Group lowering pays one out-of-line
  `eco_gc_alloc_region_fast` plus one `eco_init_*_at` per member; the singleton path pays
  neither. Never enable `ECO_GCPREPARE_MERGE` without `ECO_GCPREPARE_GROUP_INLINE` unless
  the census/A-B explicitly says otherwise.
- **Contiguity assert.** Any design admitting non-adjacent group members trips
  `assert(next->hasAttr("eco.gc_group_member"))` (EcoToLLVMHeap.cpp:2009-2010) — asserts are
  ON in the `build` preset (`-UNDEBUG`, CMakePresets.json:33-35).
- **Liveness invalidation.** `Liveness` is constructed per function at :170 and caches
  block orderings; motion **must** happen before it. Moving ops after that point silently
  corrupts root sets — the under-rooting direction, the unsafe one (EcoPipeline.cpp:88-96
  spells out the asymmetry).
- **Audit divergence.** If `isCallSafepoint` skips a call that `EcoGCLivenessAudit` still
  audits, `ECO_LOWERING_VALIDATION` builds fail with false positives (the pass compares
  attached roots against recomputed liveness, :101-111). Both must read the *same shared
  helper* — that is why the gate lives in `EcoGCLiveness.h`.
- **Nested pass / sibling-op rule.** `EcoGCLivenessAudit` is `OperationPass<func::FuncOp>`
  (:31-32) run via `addNestedPass` (EcoPipeline.cpp:101). It must never resolve a callee
  symbol. Call-local attr only — this is the contract, and here it has a concrete reason.
  (kernel-opt-08:366 says in passing "contrast kernel-opt-09, whose pass is per-function" —
  that parenthetical is stale for `EcoGCPrepare` itself, which is `OperationPass<ModuleOp>`
  at EcoGCPrepare.cpp:146-147. The call-local design still stands, for the audit twin's sake;
   09 is authoritative on this fact, 08's aside is not.)
- **Op motion must not skip the ops it crossed.** `moveAfter` while forward-iterating a block
  drags the crossed window ops behind the cursor; a plain `make_early_inc_range` loop then
  never visits them, they never enter `window`, and the very next candidate can be hoisted
  above an operand it consumes. Snapshot the block, and **retain** `window`/`winSafe`/
  `winHasCall` after a successful move. Repro shape is spelled out in the Phase-2 sketch's
  comment; a regression here is silently-invalid IR, not a verifier failure, because the
  moved op's operand is still a legal SSA value — just no longer dominating.
- **A gated classification silently zeroes the census.** If the gc-leaf exception in the
  barrier predicate were read from `ECO_GCPREPARE_MERGE`, the Phase-1 census (which runs with
  that variable unset) would report `mergeableLeaf = 0` and the plan would be descoped on a
  measurement artefact. Classification is gate-free; only the *apply* step reads a gate.
- **Divergent name lists.** The decl attr `eco.gc_leaf` is the ONE channel shared with
  kernel-opt-08; there is no `eco.kernel_cannot_gc` (v1's name — deleted). kernel-opt-12's
  `eco.cse_safe` is a *different* channel (Elm-level CSE safety, merge-only) and never
  licenses motion after EcoGCPrepare. A kernel that allocates but is stamped gc-leaf means an
  unrooted live value across a GC.
- **Merged groups grow the reservation.** `GroupLargeObjectThreshold` (32 KiB, :106) still
  caps them; the inline form needs the tighter HEAP_034 cap of 4096 bytes.
- **`func::CallOp` sites (:118) stay barriers.** Runtime helpers are not in the facts table;
  unlisted ⇒ today's behaviour (whitelist discipline).
- **Stale-.mlir gate trap.** Compiler-emitted attr + C++ passes ⇒ `--target full`, never
  `check`; and note that `full`'s first step is `--target clean` (CMakeLists.txt:1113-1120),
  which deletes the `eco-compiler.mlir` the census consumes, so census runs use
  `--target eco-compiler` (memory: capacity-check-hoisting traps).
- **The Stage-6 command is env-blind.** `add_custom_command(OUTPUT .../bin/eco-compiler …
  DEPENDS ${ECO_COMPILER_MLIR} eco-boot-native)` (compiler/CMakeLists.txt:455-462) re-runs
  only when one of those two inputs changes. A census or A/B arm that changes only an env var
  produces **no output at all** and reads as "zero opportunity". Always
  `rm -f build/compiler/build-kernel/bin/eco-compiler` first.
- **Anchor drift found while deepening:** `Compiler.Config` lives at
  `compiler/src/Compiler/Eco/Config.elm` (flags at :319-324), not
  `compiler/src/Compiler/Config.elm` (the series-contract path — it does not exist);
  the MLIR attribute plumbing lives under `compiler/src/Mlir/`, not
  `compiler/src/Compiler/Generate/MLIR/`; `UndefinedFunctionPass` validates and does not
  materialise decls (its EcoPipeline.cpp:71 comment is stale); and there is no
  `ECO_KERNEL_GCLEAF_PILOT` in the tree — kernel-opt-08 says the same (08:62), so this is
  agreement, not a conflict. Hence `ECO_GCLEAF_NAMES` as 09's standalone census input.

## Dependencies

- **kernel-opt-07-kernel-facts-table.md** — the single fact source
  (`compiler/src/Compiler/GlobalOpt/KernelFacts.elm`, keyed `(home, name)` = Mono names).
  Per the canonical contract the derived facts are **computed, never stored**:
  `canTriggerGC = gcAlloc /= GcNone || callsBackIntoElm`, `gcLeafEligible = not canTriggerGC`
  — and `gcLeafEligible` is exactly what `eco.gc_leaf` means. Do not hand-list names anywhere
  in this plan's code (the `ECO_GCLEAF_NAMES` file is census-only, never read on a default
  build, and dies with the census). Unlisted kernels keep today's EcoGCPrepare behaviour —
  safepoint + barrier — by construction, since an unstamped call carries no
  `eco.callee_gc_leaf`.
- **kernel-opt-08-kernel-gcleaf-stamp.md** — owns emission of `eco.gc_leaf` on the kernel
  `func.func` decl (Functions.elm:1995-2008) and the LLVM-side `gc-leaf-function` stamp plus
  its audit harness. 08 → 09 is the dependency spine; **Phases 1/2A of 09 can run ahead of 08
  via `ECO_GCLEAF_NAMES`**, Phases 2B/3 cannot ship without it. **Two hand-offs owed back to
  08:** (1) its backend kill switch `ECO_KERNEL_GCLEAF=0` must disable 09 as well — 09's
  marking pass consults `kernelGcLeafEnabled()` for exactly that reason, so 08 must export
  the helper from `EcoToLLVMInternal.h` rather than keeping it file-local; (2) the
  `Elm_Kernel_Utils_cmp3` decl minted in C++ by `EcoCompareCaseRewrite`
  (EcoCompareCaseRewrite.cpp:133-146) never passes through `generateKernelDecl`, so 08 must
  decide whether that site also stamps `eco.gc_leaf` — until it does, 09 simply never stamps
  cmp3 call sites (whitelist discipline, no unsoundness).
- **kernel-opt-12-eco-call-purity-attr.md** — coordination only; separate attr
  (`eco.cse_safe`, per-call, merge-only), separate semantics, no shared consultation path.
  09 reads `eco.callee_gc_leaf` and never `eco.cse_safe`; 12's D4 pins the same split. Note
  12 strips `eco.cse_safe` inside EcoGCPrepare's Step-4 loop (:328-330) — if 09's Phase 3
  makes Step 4 `continue` early on stamped calls, a call that is BOTH `eco.cse_safe` and
  `eco.callee_gc_leaf` would keep its `eco.cse_safe`, tripping 12's "must not survive
  EcoGCPrepare" verifier. Whichever of 09/12 lands second must move that strip above the
  `isCallSafepoint` guard. Flag it in the second plan's PR.
- External: HEAP_034 (shipped, default-on) is the machinery Phase 2-pre extends to groups;
  CGEN_074 capacity hoisting treats `eco_gc_alloc_region_fast` as a headroom breaker
  (EcoBackend.cpp:1744-1750) — converting groups to the inline form removes that breaker and
  may enlarge the hoistable set as a side effect (measure, do not assume). Review
  REP_*/CGEN_*/HEAP_* in invariants.csv before editing.

## Expected impact

**Wall: expect FLAT for Phases 0/1/3 — say so plainly.** Phase 3 is expected to be
*byte-identical output*, by construction: the root operands it removes are dropped at
lowering (`splitAdaptedRoots` + no-op `emitSafepointMarker`). Its payoff is compile time —
`computeLiveRoots` is O(block) per safepoint and Step 4 is therefore O(n²) in call count per
block; ~16.9% of the 17,005 kernel sites drop out — plus MLIR peak memory (shorter operand
lists on 2,873 sites). This is squarely in the class that measured flat four consecutive
times (preserve-cc, gc-leaf pilot at 64.1% dynamic coverage, capacity hoisting at −5.32 MB,
the compare phases), and unlike v1's framing it does **not** claim any stackmap or spill
saving: that saving belongs to kernel-opt-08's declaration stamp.

The only wall-capable components are (a) **Phase 2-pre**, which deletes one out-of-line call
per existing group plus one per member — deleted per-op work, the class that has actually
moved wall in this repo (inline nursery −9.6%, $cap-inlining −14.5%, CAF memoization −11.7%,
K6 hash-consing −5.07%) — and (b) **Phase 2**, which converts N inline bumps into one, again
deleted per-op work, but bounded by the Phase-1 `mergeableLeaf`/`mergeableFree` count, which
is currently unknown and, on this repo's ×4 track record of static censuses collapsing at
admissibility gates, may well be near zero. Secondary: grouping quality is a precondition for
any future group-level optimization, and the census itself resolves a standing open question
(is the allocation-group path still worth its keep post-HEAP_034?).

## Gates

1. **Phase-1 census FIRST** — no transform lands before the counts; the go/no-go table above
   is filled in with numbers in this file.
2. `ECO_LOWERING_VALIDATION` build green (configure with `-DECO_LOWERING_VALIDATION=ON`,
   the option at CMakeLists.txt:70-75 / runtime/src/codegen/CMakeLists.txt:22; it enables
   the GC liveness audit at EcoPipeline.cpp:100-102 and the boxed-slot store verifier at
   :112-120 — **not** the ptr↔i64 verifier, which is an LLVM-level pass run from EcoBackend,
   never added to this MLIR pipeline).
3. Heap-validate suite: configure a second tree with `-DECO_HEAP_VALIDATE=ON`
   (CMakeLists.txt:84-89) and run the suite once — the gate that catches under-rooting.
4. E2E, once, teed:
   `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt` then
   `grep -E "FAIL|Falsifiable|tests passed" /tmp/test_output.txt` (never `--target check`).
5. Self-host bootstrap byte-identity at the fixed point. Phase 3 must additionally be
   byte-identical **against baseline** (see its acceptance); Phases 2/2-pre legitimately
   change output, so they bootstrap to a **new** fixed point — state which in the commit.
6. Wall A/B, cold Stage 7a, interleaved 2×2, major-GC counts recorded
   (benchmarks/runtime-calls.md, "Commands" block from :60; build :62-77, workload :79-96).
7. Item-specific counters recorded here: `runs>=2` / `runObjects` / applied moves before and
   after; `safepoints` and `safepointRoots` before/after; capacity-diamond count vs the
   HEAP_034 baseline (38,603 inline diamonds, plans/inline-nursery-allocation.md:701); binary
   size split `.text` vs `.llvm_stackmaps` (`llvm-size -A`) — the capacity-hoist lesson is
   that metadata-only deltas do not move wall; MLIR-phase compile time.
8. `gc_alloc_group_baseline.mlir` green **before** Phase 2-pre touches
   `lowerOneAllocGroup` (it is the only fixture coverage the group path has, or will have);
   `gc_group_merge_leaf_call.mlir` + `gc_group_merge_bails.mlir` green in the commit that
   flips the defaults (`TEST_FILTER=codegen cmake --build build --target full`).
9. Marking-pass inertness re-checked whenever 08 moves: with `ECO_KERNEL_GCLEAF=0` the
   Phase-0 acceptance `cmp` must still be silent even with every other gate on — that is the
   single-switch rollback promised in the flag table.

---

## Phase 1 census — RESULT and go/no-go decision (2026-08-12)

Measured on the real workload (the backend lowering the compiler's own ~12 MB
module during `--target eco-compiler`), `ECO_GCPREPARE_CENSUS=1`, one run:

```
[gcleaf-mark] 10 gc-leaf decls, 798 eco.call sites stamped
[gcprepare-census] blocks=146205 groupable=80788 runs>=2=16005 runObjects=35533
[gcprepare-census] windows=2145 noCall=1917 leafOnly=228 hardBarrier=0
                   mergeableFree=40 mergeableLeaf=0 blockedDeps=2105 blockedSize=0
[gcprepare-census] safepoints=154323 roots=527779 leafSafepoints=798 leafRoots=2533
```

**Reading the counters against the plan's decision table:**

| Row | Value | Branch taken |
|---|---|---|
| `mergeableLeaf` < 500 **and** `mergeableFree` < 500 | 0 and 40 | **Descope Phase 2 entirely** |
| `blockedDeps` dominates `mergeable*` | 2,105 of 2,145 windows = **98.1%** | **Descope; do not attempt operand-chasing** |
| `runs>=2` ≥ 5,000 | **16,005** | **Phase 2-pre is a standalone win** (but see the correction below — only 1,385 of these become real groups) |

**Phase 2 / 2A / 2B are DEAD, and the kernel-facts spine is not why.** Only 2,145
merge windows exist in 146,205 blocks to begin with, and 98.1% of them are blocked
by a real SSA dependency: the later allocation consumes a result produced inside
the window or by the run it would join. That is the expected shape of
Elm-generated IR — adjacent allocations are usually *nested* constructions
(`Just (a, b)`: the tuple feeds the ctor), which is exactly the case
`consumesGroupMemberResult` already closes the group for. The dependency is
semantic, not an artefact of conservative barriers.

**The gc-leaf fact buys zero merges: `mergeableLeaf = 0`.** 228 windows were
crossable *only* because of the stamp (`leafOnly`), and **every one of those 228
was then blocked by a dependency**. So the entire premise of design-doc §8 row 3
— "two diamonds where one sufficed, split by an opaque kernel call" — does not
hold on the current tree. Filed against that row.

**`hardBarrier=0` is structural, not a finding.** The scan closes the run at a
hard barrier rather than recording a window across it, so the counter can never
be non-zero. `windows` therefore means *crossable* windows only; that is the
number the decision needs, but the column name is misleading and is called out
here so nobody later reads 0 as "no barriers exist".

**What the census DID find, and it is not what the plan was looking for:**
adjacent groupable allocations are common — `runs>=2=16005` covering 35,533
objects — and every group that forms is lowered through the out-of-line
`eco_gc_alloc_region_fast` + per-member `eco_init_*_at` call path, while a
singleton next to it gets a call-free HEAP_034 inline bump. Grouping is
currently a *pessimization* wherever the members would each lower inline. That
makes Phase 2-pre a standalone item with nothing to do with kernel boundaries,
and it is the only part of Phases 2/2-pre worth building.

**CORRECTION — `runs>=2` is NOT the number of groups that form.** The first
reading of this census said 16,005 groups / 44.0% of all groupable allocations.
That is wrong. `scanBlockForMerges` counts maximal runs of *adjacent* groupable
allocations; the real Step-1 grouping additionally closes a group at
`consumesGroupMemberResult`, the intra-group SSA dependency. Instrumenting the
actual split (`splitGroups`/`splitObjects`, added after the first run) gives the
true figure:

```
[gcprepare-census] splitGroups=1385 splitObjects=2788 keptGroups=0 keptObjects=0
```

**1,385 groups covering 2,788 objects — 3.45% of the 80,788 groupable
allocations, not 44.0%.** The same dependency wall that killed Phase 2 also
eats 91% of the runs before they ever become groups. `keptGroups=0` says every
real group was fully inline-eligible: there is not one `AllocateCtorOp` or
`AllocateStringOp` group in the entire module, so the mixed-group fallback never
fires on this workload.

The transform still deletes **1,385 `eco_gc_alloc_region_fast` calls + 2,788
`eco_init_*_at` calls = 4,173 out-of-line calls**, replacing them with 2,788
inline bumps, and shrinks the binary 25,304 B. It is worth landing on those
grounds. It is not the 44%-of-all-allocation lever the first reading implied,
and no downstream plan should be sized off that number.

**Phase 3 is small but real:** 798 stamped call sites are safepoints today,
carrying 2,533 root operands — 0.52% of the 154,323 safepoints and 0.48% of the
527,779 root operands. Those operands are computed by an O(block²) analysis and
then **discarded at lowering**, so removing them is pure compile-time with a
byte-identical binary. 0.5% of one pass is not going to show up on a wall clock;
it lands because it is nearly free and because it is the correctness-shaped half
of the plan.

**Decision: ship Phase 0 (fact channel) + Phase 3 (safepoint relaxation) +
Phase 2-pre (inline-bump group lowering). Drop Phases 2, 2A, 2B.**

---

## Outcome — 2026-08-12: SHIPPED, PARTIAL (Run N)

**Landed:** Phase 0 (fact channel) + Phase 3 (safepoint relaxation) +
Phase 2-pre (inline-eligible groups are not grouped), all DEFAULT-ON.
**Dropped:** Phases 2 / 2A / 2B, on the Phase-1 census — see the decision
section above. Contract written up as **CGEN_077**; KERNEL_FACTS_001 amended to
name the marker pass now that it exists.

**Flags** (all default-on, each independently reversible):

| switch | effect |
|---|---|
| `ECO_GCLEAF_MARK=0` | `EcoMarkGCLeafCalls` stamps nothing; leaves kernel-opt-08 alone |
| `ECO_GCPREPARE_LEAF_SAFEPOINT=0` | stamped calls are safepoints again (both consumers) |
| `ECO_GCPREPARE_SPLIT_INLINE_GROUPS=0` | inline-eligible runs are grouped again |
| `ECO_GCPREPARE_CENSUS=1` | prints the four census lines |
| `ECO_KERNEL_GCLEAF=0` | kernel-opt-08's switch; the marking pass honours it |

**Measured (Run N):**

| | value |
|---|---|
| calls stamped `eco.callee_gc_leaf` | 798 (from 10 gc-leaf decls) |
| safepoints | 154,323 → 153,525 (**−798**, exactly the stamped count) |
| root operands | 527,779 → 525,246 (**−2,533**) |
| groups no longer formed | **1,385**, covering 2,788 objects |
| out-of-line calls deleted | **4,173** (1,385 region + 2,788 init) |
| binary | −25,304 B; `.text` +16,192, `.llvm_stackmaps` −40,104 |
| wall | −0.23% ⇒ FLAT |

**Phase 3 acceptance held: byte-identical.** With the split forced off in both
arms, the produced `eco-compiler` is identical with the relaxation on and off,
confirming the analysis that the MLIR root operands are discarded at lowering.
An earlier run of this gate reported DIFFERS; that was measurement error on my
part — `EcoGCPrepare.cpp` was edited between the two arms and
`--target eco-compiler` re-ran ninja for the second, so the arms differed by
Phase 2-pre as well. Re-run on a frozen tree it passes, and the isolated
Phase-2-pre arm accounts for exactly the −25,304 B that had shown up as the
"failure". **Freeze `runtime/src` as well as `compiler/src` while an arm build
is in flight** — the same trap the loop guide already records for the front end.

**Whole-item inertness:** with both flags off, `eco-compiler` is byte-identical
to the pre-item-09 build. The fact channel alone (stamping 798 attrs that
nothing reads) is also byte-identical, verified separately via `ECO_GCLEAF_MARK`.

**Fixture:** `test/codegen/gc_group_split_inline.mlir` pins both directions of
the split and is the **first fixture the allocation-group lowering has ever
had** — the plan's Phase-1 observation that `grep -rln 'gc_group' test/` returned
nothing was correct.

**Phase 3 has no fixture, deliberately.** It is byte-identical at LLVM level by
design, and there is no emit mode between `EcoGCPrepare` and LLVM lowering
(`-emit=mlir` dumps the input, `-emit=mlir-eco` stops before Stage 2.5), so a
codegen fixture could only assert something untrue. Its evidence is the census
delta and the byte-identity gate, both recorded above.

**Gates run:** E2E `--target full` **1643/1643** default-on and again with both
kill switches; the new fixture green; census `eco-compiler` byte-identical to
baseline. **Not run** (removed from the loop by instruction): heap-validate
tree, `--target bootstrap`, `elm-tests`.

**Hand-off to kernel-opt-12:** the ordering hazard in Phase 3's write-up is now
live. `isCallSafepoint` returns false for stamped calls, so a call that is both
`eco.cse_safe` and `eco.callee_gc_leaf` short-circuits before Step 4's strip.
**12 must hoist its `eco.cse_safe` strip above the `isCallSafepoint` guard**
(EcoGCPrepare.cpp Step 4) or its "must not survive EcoGCPrepare" verifier will
fire on those calls.
