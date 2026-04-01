# GC Safepoint Relocate Implementation

## Status: READY FOR IMPLEMENTATION
## Priority: High
## Prerequisite: Builds on existing statepoint infrastructure (see llvm-statepoint-gc-roots.md)

---

## 0. Goal

Make GC safe by ensuring:
1. Every potential GC point (allocation + call + papExtend) has a safepoint.
2. Every safepoint lowers to `gc.statepoint` + `gc.relocate` with SSA rewriting.
3. Post-safepoint code uses relocated pointers, never stale ones.

**Deferred:** Fast/slow allocation path splitting, loop back-edge safepoints.

---

## 1. StatepointConversion: Emit `gc.relocate` + SSA Rewrite

**File:** `runtime/src/codegen/Passes/StatepointConversion.cpp`

### Current State

`convertSafepointMarkers` already:
- Finds `__eco_safepoint_marker` calls (created by `SafepointOpLowering` in `EcoToLLVMErrorDebug.cpp`)
- Replaces each with `llvm.experimental.gc.statepoint` intrinsic
- Attaches arguments as `gc-live` operand bundle
- Creates `__eco_gc_safepoint_nop` as the no-op callee

**Missing:** No `gc.relocate` emission, no SSA use rewriting.

### Steps

#### Step 1.1: Add helper functions

Add at the top of `StatepointConversion.cpp`:

- `stripIntToPtr(Value*)` — if value is `IntToPtrInst(i64)`, return the i64 operand; else nullptr.
  - **Confirmed safe:** `SafepointOpLowering` always emits `IntToPtrOp(i64 → ptr addrspace(1))` for every live root. There are no other producers of `__eco_safepoint_marker` calls. This pattern will always match.
- Include `<llvm/IR/Dominators.h>` for `DominatorTree`.

#### Step 1.2: Build DominatorTree per function

Inside `convertSafepointMarkers`, after collecting marker calls for a function, build once:
```cpp
llvm::DominatorTree DT(F);
```

**Confirmed:** DomTree remains valid throughout processing because:
- Statepoint conversion replaces one `CallInst` with another in-place — no blocks split, no branches added/removed.
- `gc.relocate` and `ptrtoint` insertions are intra-BB instruction additions that don't affect BB-granularity dominance.
- No need to rebuild or incrementally update.

#### Step 1.3: Track original i64 values

For each marker call's arguments:
- Each arg is `ptr addrspace(1)` (from `IntToPtrOp` in `SafepointOpLowering`)
- Use `stripIntToPtr` to find the underlying `i64` HPointer SSA value
- Build `SmallVector<Value*, 8> originalInts` in gc-live operand order

#### Step 1.4: Emit `gc.relocate` after statepoint

After inserting the statepoint call, use `IRBuilder` positioned at `statepoint->getNextNode()`:

For each original i64 at index `i`:
1. `gc.relocate(token, baseIdx=i, derivedIdx=i)` → `ptr addrspace(1)`
2. `ptrtoint` the relocated ptr → `i64`
3. Store in `SmallVector<Value*, 8> relocatedInts`

**Token usage:** The `CallInst*` of the statepoint intrinsic call has result type `token` and is directly usable as the first operand to `gc.relocate`. No extraction needed.

**LLVM version note:** Eco targets LLVM 14+ (ORC v2 APIs). `gc.relocate` returns `ptr addrspace(1)` in modern LLVM. Verify exact version via `find_package(LLVM)` / `LLVM_PACKAGE_VERSION` in CMake during implementation and cross-check the intrinsic declaration against that version's docs.

#### Step 1.5: Rewrite post-safepoint SSA uses

For each `(originalInts[i], relocatedInts[i])`:
- Iterate over `originalInts[i]->uses()` and for each `Use &U` where `User` is an `Instruction`:
  - Skip if user == statepoint
  - Skip if user is one of the relocate/ptrtoint instructions we just created
  - If `DT.dominates(statepoint, cast<Instruction>(U.getUser()))` → `U.set(relocatedInts[i])`

**Important:** Do this after all relocates are inserted but before erasing the marker call.

#### Step 1.6: Process multiple safepoints correctly

Process safepoints in **forward program order** (forward within each BB, then by dominance).

Edge cases to handle:
1. **Multiple safepoints in one block:** Walk instructions forward; after inserting relocates for statepoint S1, uses between S1 and S2 get rewritten to S1's relocated values. S2's marker args then reference S1's relocated values — this is correct (they are the live values at S2).
2. **Different liveness sets:** Each safepoint has its own live-root set from the marker args. The original→relocated mapping is per-statepoint, not global.
3. **Values killed between safepoints:** If a value is not in S2's live set, it gets no relocate at S2 — correct by construction since the Elm compiler controls liveness.
4. **Phi / control-flow joins:** When safepoints appear in both branches before a join, phi operands must use the relocated values from their respective branches. The DT-based rewriting handles this correctly since each branch's uses are dominated by their respective statepoint.

#### Step 1.7: Cleanup + assertion

After processing all markers:
```cpp
assert(module.getFunction("__eco_safepoint_marker") == nullptr &&
       "All safepoint markers must be converted to statepoints");
```

---

## 2. ThreadLocalHeap: Debug Logging for Non-Indirect Roots

**File:** `runtime/src/allocator/ThreadLocalHeap.cpp`

### Current State

`collectStackRootsFromStackMap()` (lines 177-238):
- Walks stack via RBP chaining
- Only handles `StackMapLocation::Indirect` with `dwarfRegNum == 6` (RBP)
- Silently ignores Register, Direct, Constant, ConstantIndex

### Step 2.1: Add conditional warnings

In the switch on `loc.kind`, add a debug-build warning for non-Indirect kinds:
```cpp
case StackMapLocation::Register:
case StackMapLocation::Direct:
case StackMapLocation::Constant:
case StackMapLocation::ConstantIndex:
#if ECO_DEBUG_STACKMAP
    fprintf(stderr, "[eco-gc] WARNING: unsupported stackmap location kind=%u "
        "reg=%u offset=%d at returnAddress=%p\n",
        (unsigned)loc.kind, loc.dwarfRegNum, loc.offset,
        (void*)returnAddress);
#endif
    break;
```

### Step 2.2: Define ECO_DEBUG_STACKMAP

Add `ECO_DEBUG_STACKMAP` as a CMake option, enabled in debug builds (`CMAKE_BUILD_TYPE=Debug`). Use `target_compile_definitions` in the allocator's CMakeLists.txt.

---

## 3. Elm Compiler: Add Safepoints Before Calls and papExtend

### Current State

- `emitSafepoint` (Expr.elm:98-100) wraps `Ops.ecoSafepoint` — computes live `!eco.value` vars via `Ctx.liveEcoValueVars` and emits `eco.safepoint`
- Safepoints exist before `eco.construct.*` (allocation sites)
- **No safepoints before `eco.call` or `eco.papExtend`**

### Liveness correctness (A1/A2 resolved)

`emitSafepoint` uses `Ctx.liveEcoValueVars` which returns all currently in-scope `!eco.value` SSA variables. Since safepoints are inserted *after* argument evaluation but *before* the call/papExtend, the just-computed arguments are already in the context and will be included in the live set. **Verify during implementation** that `Ctx.freshVar` / argument binding adds vars to the live set before `emitSafepoint` is called.

### Step 3.1: Safepoints before kernel calls in Expr.elm

**Affected call sites** (approximate lines):
- Line ~561-576: Zero-arity function calls
- Line ~717-725: Kernel calls
- Other kernel call emission sites

Pattern change at each site:
```elm
-- Before:
( ctx2, callOp ) = Ops.ecoCallNamed ctx1 var funcName args type

-- After:
( ctxSp, spOp ) = emitSafepoint ctx1
( ctx2, callOp ) = Ops.ecoCallNamed ctxSp var funcName args type
-- Include spOp in ops list before callOp
```

### Step 3.2: Safepoints before lambda/closure calls in Expr.elm

**Affected:** Line ~1002-1003 (direct closure call via `ecoCallNamed`)

Same pattern as Step 3.1.

### Step 3.3: Safepoints before Bytes.encode calls in Expr.elm

**Affected:** Line ~2262-2263

Same pattern as Step 3.1.

### Step 3.4: Safepoints before main entry call in Functions.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Functions.elm`
**Affected:** Lines ~42-62

```elm
-- Before:
( ctx2, callOp ) = Ops.ecoCallNamed ctx1 callVar mainFuncName [] Types.ecoValue

-- After:
( ctxSp, spOp ) = emitSafepoint ctx1
( ctx2, callOp ) = Ops.ecoCallNamed ctxSp callVar mainFuncName [] Types.ecoValue
-- region body includes [ spOp, callOp ]
```

### Step 3.5: Safepoints before `eco.papExtend` in Expr.elm

**Confirmed required:** `eco.papExtend` is the central "apply closure / PAP" operation. It lowers to closure/PAP logic in `EcoToLLVMClosures.cpp` that can allocate and may call back into arbitrary Elm code. It always produces `!eco.value` and is not a pure bookkeeping op.

Safepoints needed before papExtend at:
- Line ~1367 (generic apply)
- Line ~1463 (segmentation unknown)
- Line ~1620 (staged application chain — each papExtend in the chain)
- Line ~1731 (direct staged apply)

Same pattern: `emitSafepoint` before each `eco.papExtend`, include `spOp` in ops.

### Step 3.6: Safepoints for non-construct allocations

**Gap identified (A3 resolved):** `eco.string_literal`, `eco.allocate_string`, and other non-construct `eco.allocate*` ops that lower to runtime allocation functions (`eco_allocate`, `eco_alloc_custom`, `eco_alloc_string`, `eco_alloc_closure`) do **not** currently have safepoints.

**Resolution options:**
1. Have the compiler emit `eco.safepoint` before any op that lowers to a heap allocation (including string literals).
2. Rely on lowering patterns that introduce statepoints around the LLVM calls for these allocations.

**Recommendation:** Option 1 (compiler-side) is more consistent with the existing pattern for constructs. During implementation, audit all `eco.allocate*` emission sites and add safepoints where missing.

### Step 3.7: Leave construct-side safepoints unchanged

Existing safepoints before `eco.construct.*` remain as-is.

---

## 4. Pipeline Ordering: Verify (No Functional Changes)

### Current State (Confirmed Correct)

Pipeline order:
1. MLIR Eco dialect → MLIR LLVM dialect (via `buildEcoToLLVMPipeline` in `EcoPipeline.cpp`)
   - `SafepointOpLowering` converts `eco.safepoint` → `__eco_safepoint_marker` call with `inttoptr` args
2. MLIR LLVM dialect → LLVM IR (via `translateModuleToLLVMIR`)
3. `convertSafepointMarkers(*llvmModule)` → replaces markers with `gc.statepoint` + `gc.relocate`
4. LLVM optimization + codegen

This runs in all three code paths:
- `ecoc.cpp` (AOT at line ~185, JIT transformer at ~239)
- `EcoRunner.cpp` (JIT transformer at ~185)
- `eco-boot.cpp` (bootstrap)

### Step 4.1: Add post-pass assertion

After `convertSafepointMarkers` returns in all three callers, assert the marker function is gone. This is defensive and low-risk.

---

## 5. Tests

### Step 5.1: Extend `safepoint_statepoint_emission.mlir`

**File:** `test/codegen/safepoint_statepoint_emission.mlir`

Currently checks for:
- `gc "statepoint-example"` on functions
- `@llvm.experimental.gc.statepoint.p0`
- `"gc-live"` operand bundle

Add FileCheck assertions for:
- `@llvm.experimental.gc.relocate` calls after each statepoint
- `ptrtoint` of relocated `ptr addrspace(1)` back to `i64`
- Correct number of relocates matching number of live roots

### Step 5.2: New test: Multiple roots with post-safepoint uses

Add a new `.mlir` test where:
- Two `eco.value` variables are defined
- `eco.safepoint` lists both as live
- Both are used after the safepoint (in subsequent ops)
- FileCheck verifies post-safepoint uses reference relocated values, not originals

### Step 5.3: New test: Safepoint across control flow

Add a test with an `eco.safepoint` followed by a branch, where both successors use the live roots. Verify SSA rewrite applies in both branches.

### Step 5.4: New test: Two safepoints in one block

Add a test exercising the edge case of multiple safepoints in a single basic block. Verify that the second safepoint's live roots reference the first's relocated values.

### Step 5.5: E2E GC stress test

Write a small Elm program that:
- Allocates a structure, keeps it in a local
- Calls a function that allocates heavily (triggers GC)
- Reads fields from the local after the call
- Verifies values are intact

Compile with `-emit=llvm` and inspect for `gc.statepoint` + `gc.relocate`.

### Step 5.6: StackMap debug assertion test

In debug builds, run a representative program and verify no `[eco-gc] WARNING: unsupported stackmap location` messages appear.

---

## 6. Implementation Order

1. **Step 1 (StatepointConversion.cpp)** — Core `gc.relocate` + SSA rewrite. Most complex and foundational.
2. **Step 5.1-5.4 (IR tests)** — Verify LLVM-level behavior works correctly in isolation.
3. **Step 3 (Elm compiler safepoints)** — Add safepoints before all calls, papExtend, and non-construct allocations.
4. **Step 2 (ThreadLocalHeap debug logging)** — Small, low-risk.
5. **Step 4 (Pipeline assertions)** — Defensive, low-risk.
6. **Step 5.5-5.6 (E2E + debug tests)** — Final validation.

---

## 7. Resolved Questions

All questions from the planning phase have been answered:

| # | Question | Resolution |
|---|----------|------------|
| Q1 | `eco.papExtend` safepoints | **Yes, required.** papExtend is the central closure apply op, can allocate and call arbitrary Elm code. Added as Step 3.5. |
| Q2 | DomTree validity after statepoint insertion | **Valid.** In-place CallInst replacement + intra-BB instruction additions don't affect BB-granularity dominance. No rebuild needed. |
| Q3 | Forward processing edge cases | **Safe with care.** Per-statepoint mapping, forward order correct. Four specific edge cases documented in Step 1.6; tests added in Step 5.4. |
| Q4 | LLVM version / gc.relocate signature | **LLVM 14+ (ORC v2).** `gc.relocate` returns `ptr addrspace(1)`. Verify exact version from CMake during implementation. |
| Q5 | CallInst* as token for gc.relocate | **Yes.** Statepoint CallInst has result type `token`, directly usable as first operand to gc.relocate. |
| A1 | emitSafepoint captures call arguments | **Yes by design.** `liveEcoValueVars` includes all in-scope vars. Safepoint emitted after arg evaluation, before call. Verify during implementation that freshVar adds to live set. |
| A3 | Non-construct allocations have safepoints | **No, gap exists.** `eco.string_literal` and `eco.allocate*` lack safepoints. Added as Step 3.6 to audit and fix. |
| A4 | stripIntToPtr always finds i64 | **Yes, confirmed.** SafepointOpLowering always emits `IntToPtrOp(i64 → ptr addrspace(1))` for every live root. No other marker producers exist. |

### Remaining assumptions to verify during implementation

**A2:** `emitSafepoint` correctly over-approximates live roots at each call site. Specifically, verify that `Ctx.freshVar` / argument binding adds vars to the live set before `emitSafepoint` is called.

**A5:** `eco-boot.cpp` calls `convertSafepointMarkers` identically to ecoc/EcoRunner — confirm same behavior.

### Deferred (explicitly out of scope)

- Fast/slow allocation path splitting
- Loop back-edge safepoints (`scf.while` headers)
- Interior pointer support (base != derived in gc.relocate)
- Write barriers (not needed due to Elm's immutability)
- Register/Direct root support in `collectStackRootsFromStackMap` (rely on LLVM spilling via gc.relocate)
