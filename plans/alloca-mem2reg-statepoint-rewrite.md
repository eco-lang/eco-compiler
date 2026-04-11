# Plan: Alloca/mem2reg-based Statepoint GC Root Rewriting

**Status:** READY FOR IMPLEMENTATION  
**Problem:** The current `convertSafepointMarkers` uses `DT.dominates()` to directly rewrite SSA uses of GC roots to their `gc.relocate` results. This approach fails for loop-invariant roots: a value defined before a loop that is live across a safepoint inside the loop body doesn't get a phi at the loop header, so post-GC iterations use a stale (pre-relocation) pointer.  
**Solution:** Replace the direct SSA rewrite (lines 172–223 of `StatepointConversion.cpp`) with an alloca/mem2reg pattern. Each GC root gets an alloca; stores update it after definition and after each `gc.relocate`; all uses become loads; then `PromoteMemToReg` synthesizes correct phis automatically.

---

## Resolved Questions

All questions from the design phase have been answered:

- **Q1 (gc-live bundle operands):** Do **not** skip gc-live uses. Rewrite them too, so gc-live always references the current value. For gc-live operands, emit `inttoptr(load %V.alloca) to ptr addrspace(1)` so the bundle tracks the correct value. After mem2reg, the load becomes the correctly-phi'd SSA root.
- **Q2 (alloca type):** Keep allocas as `i64` (matching HPointer representation). Use `inttoptr` at the statepoint boundary only. This avoids pushing `ptrtoint`/`inttoptr` shims into every runtime call and heap store.
- **Q3 (Phase split):** Emit `gc.relocate` in Phase 2, not Phase 1. Phase 1 only creates statepoints and records `(SP, LiveRoots, LiveIndices)`. Phase 2 creates relocates + allocas + stores + loads + mem2reg. Cleaner data flow.
- **Q4 (Loop test infra):** Existing infra is sufficient. Write MLIR tests with `eco.safepoint` inside loops using `eco.joinpoint`/`eco.jump` or `scf.while`. No infra changes needed.
- **Q5 (DominatorTree):** Compute DomTree only in Phase 2 for `PromoteMemToReg`. Phase 1 doesn't need it — process markers in lexical order since each statepoint is self-contained.

## Confirmed Assumptions

1. `eco.value` → `i64` always (no `ptr addrspace(1)` representation today).
2. Marker args always have the `inttoptr i64 → ptr addrspace(1)` pattern.
3. The three call sites (`eco-boot.cpp`, `ecoc.cpp`, `EcoRunner.cpp`) need no changes.
4. `PromoteMemToReg` before general optimization is safe (matches upstream `RewriteStatepointsForGC` practice).

---

## Step 1: Update header comments

**File:** `runtime/src/codegen/Passes/StatepointConversion.h`

- Update the doc comment on `convertSafepointMarkers` to describe the new two-phase alloca/mem2reg strategy.
- No signature changes. No new public APIs.

---

## Step 2: Add includes and helper types

**File:** `runtime/src/codegen/Passes/StatepointConversion.cpp`

Add new includes:
```cpp
#include "llvm/Transforms/Utils/PromoteMemToReg.h"
#include "llvm/ADT/DenseSet.h"
```

Add helper types in the anonymous namespace:
```cpp
struct SafepointInfo {
    CallBase *Statepoint;
    SmallVector<Value *, 8> LiveRoots;       // original i64 values (stripped from inttoptr)
    SmallVector<unsigned, 8> LiveIndices;     // index of each root in the gc-live bundle
    // gc-live bundle operands are ptr addrspace(1) (the inttoptr results)
    SmallVector<Value *, 8> GCLivePtrArgs;   // the ptr addrspace(1) values in the gc-live bundle
};
```

Add helper predicates:
- `isGCManagedType(Type*)` — returns true for `i64` (our HPointer representation).
- `isGCLiveOperandOfStatepoint(CallBase*, Use*)` — checks if a Use belongs to a `"gc-live"` operand bundle. **Note:** this is used during initial-store skipping only (see step 4e), NOT to skip gc-live rewrites.

---

## Step 3: Refactor Phase 1 — marker-to-statepoint conversion (no gc.relocate)

**File:** `runtime/src/codegen/Passes/StatepointConversion.cpp`

Extract into a static function:
```cpp
static bool convertMarkersToStatepoints(
    Module &M,
    DenseMap<Function*, SmallVector<SafepointInfo, 4>> &OutMap);
```

This function:
1. Finds all `__eco_safepoint_marker` calls, groups by function.
2. Sorts markers in lexical program order (no DomTree needed — just use `comesBefore` within blocks and block ordering).
3. For each marker:
   a. Collects gc-live args (`ptr addrspace(1)`) and strips IntToPtr to get original `i64` values.
   b. Finds target call via `findTargetCall()`.
   c. Builds `gc.statepoint` with the gc-live operand bundle (using `ptr addrspace(1)` args).
   d. Emits `gc.result` if target is non-void.
   e. Records `SafepointInfo { SP, LiveRoots (i64), LiveIndices, GCLivePtrArgs }`.
   f. Erases marker and target call.
4. Erases marker function declaration.
5. Returns `true` if any markers were converted.

**Key difference from current code:**
- No `gc.relocate` emission here (deferred to Phase 2).
- No DomTree construction.
- No SSA use rewriting.

---

## Step 4: Implement Phase 2 — gc.relocate + alloca/mem2reg rewrite

**File:** `runtime/src/codegen/Passes/StatepointConversion.cpp`

New static function:
```cpp
static bool rewriteGCRootsWithAllocas(
    Function &F,
    ArrayRef<SafepointInfo> Safepoints);
```

### 4a. Collect all unique GC root values
Iterate all `SafepointInfo.LiveRoots` across the function's safepoints. Deduplicate into a `DenseSet<Value*>`. Filter to `isGCManagedType` (i.e., `i64`).

### 4b. Create one alloca per GC root in the entry block
Insert at `Entry.getFirstInsertionPt()`, before any non-alloca instructions. Type: `i64`. Name: `V->getName() + ".gcroot"`. Store in `DenseMap<Value*, AllocaInst*> Allocas`.

### 4c. Insert initial store for each root
- If `V` is an `Argument`: store after all allocas/dbg intrinsics in the entry block.
- If `V` is a `PHINode`: store at `getParent()->getFirstNonPHI()`.
- If `V` is any other `Instruction`: store immediately after `V`, skipping dbg intrinsics.

### 4d. For each statepoint: emit gc.relocate, then store into alloca

For each `SafepointInfo`:
1. Set insertion point after the statepoint (after gc.result if present, skipping dbg intrinsics).
2. For each live root `i`:
   - Emit `gc.relocate(SP_token, LiveIndices[i], LiveIndices[i])` → produces `ptr addrspace(1)`.
   - Emit `ptrtoint` to convert back to `i64`.
   - `CreateStore(relocated_i64, Allocas[LiveRoots[i]])`.

### 4e. Rewrite ALL uses of each root V to loads from its alloca

For each root `V`, iterate `V->uses()` and rewrite all uses **except**:
- The initial store created in 4c (identified by: `StoreInst` where `getValueOperand() == V && getPointerOperand() == Allocas[V]`).
- **Do NOT skip gc-live bundle uses** — these must also be rewritten to track the current value.

For each use being rewritten:
- Insert `load i64, i64* %V.alloca` immediately before the user instruction.
- If the use is a gc-live bundle operand (which expects `ptr addrspace(1)`), also insert `inttoptr i64 %loaded to ptr addrspace(1)` and use that as the replacement.
- Otherwise, use the `i64` load directly.

**Handling gc-live operand rewriting detail:** The gc-live operands in the statepoint were originally `ptr addrspace(1)` (inttoptr of the original i64). After rewriting, they become `inttoptr(load(alloca))`. After mem2reg, the load disappears into SSA and the gc-live operand becomes the correctly-phi'd relocated value (as ptr addrspace(1)).

### 4f. Promote allocas back to SSA
```cpp
DominatorTree DT(F);
PromoteMemToReg(AllocaVec, DT);
```

This synthesizes correct phis for loops, diamonds, etc. Loop-carried roots automatically get:
```
%v.loop = phi [ %v.entry, %entry ], [ %v.reloc, %latch ]
```

---

## Step 5: Wire up the top-level function

**File:** `runtime/src/codegen/Passes/StatepointConversion.cpp`

Rewrite `eco::convertSafepointMarkers`:
```cpp
bool eco::convertSafepointMarkers(Module &M) {
    DenseMap<Function*, SmallVector<SafepointInfo, 4>> SPMap;
    bool Changed = convertMarkersToStatepoints(M, SPMap);
    if (!Changed) return false;
    for (auto &[F, SPs] : SPMap)
        rewriteGCRootsWithAllocas(*F, SPs);
    return true;
}
```

**Delete** the old dominance-based use-rewriting code (current lines 98–106 DomTree sort, lines 172–223 use rewriting).

---

## Step 6: Leave `removeDeadGCRelocates` unchanged

The existing logic (lines 242–330) remains correct:
- Dead gc.relocate + ptrtoint cleanup: still needed because Phase 2 emits gc.relocate for *all* roots, and mem2reg may eliminate stores/loads for roots with no post-statepoint uses, leaving the gc.relocate dead.
- Relocate reordering: still needed for gc.relocates that survive inlining across function boundaries during optimization.

---

## Step 7: Update existing tests

**Files:** `test/codegen/safepoint_relocate_ssa_rewrite.mlir`, `test/codegen/safepoint_two_in_one_block.mlir`

The new approach still emits `gc.relocate` in the LLVM IR output. Review and update CHECK lines if:
- gc.relocate ordering changes (now emitted for all roots, not just those with dominated uses).
- mem2reg introduces phi nodes visible in the output.
- The `safepoint_two_in_one_block` test should now show the second statepoint's gc-live referencing the relocated value from the first (via mem2reg phi/SSA), not the original `%a`.

---

## Step 8: Add new test — loop with safepoint

**File:** `test/codegen/safepoint_loop_gc_relocate.mlir` (new)

Minimal MLIR test: a function with a loop (`scf.while` or `eco.joinpoint`/`eco.jump`) containing an `eco.safepoint` and a call. The loop-carried value is a GC root.

CHECK that in the LLVM IR output:
- No alloca remains (mem2reg promotes it away).
- A `phi` at the loop header carries the root value.
- `gc.relocate` + `ptrtoint` feeds into the phi's back-edge input.
- The original argument is NOT used directly in the loop body after the statepoint.

This is the primary regression test for the motivating bug.

---

## Step 9: Add negative tests

**File:** `test/codegen/safepoint_no_gc_roots.mlir` (new)

Two test cases:
1. Function with `eco.safepoint` but no GC-managed roots (e.g., only non-pointer arguments): statepoint is still emitted but no `gc.relocate` appears.
2. Function with no `eco.safepoint` at all: pass is a no-op, no statepoint intrinsics in output.

---

## Step 10: Run full E2E test suite

```bash
cmake --build build --target full
```

Specifically watch for:
- `Bytes_Decode_loopHelp` regression (the motivating bug) — crash in `eco_pap_extend` should disappear.
- Any GC-related crashes in Stage 7.
- `removeDeadGCRelocates` assertion failures (SelectionDAG visiting).
- Heap sanity checks passing after many GC cycles.

---

## Implementation Notes

### What to delete
- Lines 98–106: DomTree construction + sort in the main loop (Phase 1 uses lexical order instead).
- Lines 172–223: The `allUsesToRewrite` collection and direct SSA rewriting logic. This is the core of the old approach and is entirely replaced by Phase 2.

### What to keep
- `stripIntToPtr()` helper (line 38–43): still used in Phase 1 to extract i64 from marker args.
- `findTargetCall()` helper (line 48–63): still used in Phase 1.
- `removeDeadGCRelocates()` (lines 242–330): unchanged.
- Statepoint construction logic (lines 127–169): kept in Phase 1, minus the use-rewriting part.

### Edge cases to handle
- **PHI nodes as GC roots:** Insert initial store at `getParent()->getFirstNonPHI()`, not after the PHI itself.
- **Root appears in multiple safepoints:** One alloca, multiple post-statepoint stores. Correct by construction.
- **gc.result between statepoint and gc.relocate:** Phase 2 must insert gc.relocate after the gc.result (if present), same as current code handles `insertAfter` logic.
- **inttoptr instructions from old marker lowering:** After Phase 2 rewrites gc-live operands to `inttoptr(load(alloca))`, the original `inttoptr` instructions (created by SafepointOpLowering) may become dead. They'll be cleaned up by DCE in the optimization pipeline.
