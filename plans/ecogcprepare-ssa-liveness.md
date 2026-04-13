# Plan: EcoGCPrepare as Single Source of Truth for GC Roots via SSA Liveness

## Problem

`computeLiveEcoValues()` in `EcoGCPrepare.cpp:37-71` implements a **block-local** liveness heuristic. It collects `!eco.value` SSA values defined in the same block (block args + op results before the target) that have any use at or after the target op. This misses:

1. **Loop back-edge state**: In tail-recursive loops lowered to `eco.jump` → cf branch, the loop-state values (closure, args) are block arguments at the loop header. When `eco.safepoint` sits in the back-edge block before the jump, `computeLiveEcoValues` may produce an empty or incomplete root set because the temporaries used by the jump aren't in `Ctx.liveEcoValueVars` and the heuristic doesn't do cross-block dataflow.

2. **Cross-block liveness in general**: Values defined in dominating blocks that are live across a safepoint in a successor block are not reliably captured.

The fix: replace the custom heuristic with MLIR's `Liveness` analysis (`mlir/Analysis/Liveness.h`), which performs proper fixpoint-based inter-block dataflow to compute live-in/live-out sets and per-value liveness queries.

## Target Contract

After this change:

- **EcoGCPrepare is authoritative**: For every `GCRootCarrier` op (safepoint, alloc, call, papCreate, papExtend, construct.*), it computes the set of live `!eco.value` SSA values using MLIR `Liveness` and writes them via `setGCRoots`.
- **Front-end operands are advisory**: `emitSafepoint` in `Expr.elm` still emits operands from `Ctx.liveEcoValueVars`, but EcoGCPrepare overwrites them. Correctness does not depend on the front-end list.
- **Lowering does not recompute**: EcoToLLVM and `emitAllocWithSafepoint` consume roots from op adaptors as final (no change needed).

## Invariants

After EcoGCPrepare runs, every `GCRootCarrier` op's root set satisfies:
- **Sound**: includes all `!eco.value` values that are live after the op (have a use reachable from that point without redefinition).
- **Conservative**: may over-approximate; under-approximation is forbidden.
- Covers block arguments, loop-carried values, temporaries from `generateTailCall`, and cross-block SSA values.

---

## Implementation Steps

### Step 1: Add MLIRAnalysis link dependency

**File**: `CMakeLists.txt` for the codegen library (wherever `EcoGCPrepare.cpp` is compiled)

Add `MLIRAnalysis` to `target_link_libraries`. This is required for `#include "mlir/Analysis/Liveness.h"`.

### Step 2: Replace `computeLiveEcoValues` with `computeLiveRoots`

**File**: `runtime/src/codegen/Passes/EcoGCPrepare.cpp`

1. Add `#include "mlir/Analysis/Liveness.h"`.
2. Remove `computeLiveEcoValues()` (lines 37-71).
3. Add a new helper `computeLiveRoots(Liveness &, Operation *op)`:

```cpp
static SmallVector<Value, 8> computeLiveRoots(Liveness &liveness,
                                               Operation *targetOp) {
    SmallVector<Value, 8> roots;
    llvm::DenseSet<Value> seen;
    Block *block = targetOp->getBlock();
    if (!block) return roots;

    auto consider = [&](Value v) {
        if (!isEcoValue(v)) return;
        if (!seen.insert(v).second) return;
        if (!liveness.isDeadAfter(v, targetOp))
            roots.push_back(v);
    };

    // Candidate set 1: values live-in to this block (cross-block liveness)
    const auto &liveIn = liveness.getLiveIn(block);
    for (Value v : liveIn)
        consider(v);

    // Candidate set 2: block arguments
    for (auto arg : block->getArguments())
        consider(arg);

    // Candidate set 3: results of ops defined before targetOp in this block
    for (auto &op : block->getOperations()) {
        if (&op == targetOp) break;
        for (auto result : op.getResults())
            consider(result);
    }

    return roots;
}
```

Key design choices:
- **Candidate set + `isDeadAfter`**: Matches how other MLIR passes (e.g. buffer deallocation) use liveness. Efficient because `isDeadAfter` is a per-value query and the candidate set is bounded.
- **`liveIn(block)` as safety net**: Captures cross-block values (defined in dominating blocks) that are live through this block. This is what the old heuristic missed entirely.
- **`isDeadAfter` semantics**: Returns true if the value has no uses reachable after `targetOp`. So `!isDeadAfter` = "live after" = must be a root.

### Step 3: Thread Liveness through processFunction/processBlock

**File**: `runtime/src/codegen/Passes/EcoGCPrepare.cpp`

```cpp
void processFunction(func::FuncOp func) {
    if (func.isExternal()) return;
    Liveness liveness(func);  // computed once per function
    for (Block &block : func.getBody()) {
        processBlock(block, liveness);
    }
}

void processBlock(Block &block, Liveness &liveness) {
    // ... existing grouping + safepoint + call-safepoint logic ...
    // All three loops now call computeLiveRoots(liveness, op)
    // instead of computeLiveEcoValues(op).
}
```

The three processing loops (alloc groups, explicit safepoints, call-like safepoints) remain structurally unchanged. Only the liveness computation is replaced.

### Step 4: Add debug assertion — front-end roots ⊆ computed roots

**File**: `runtime/src/codegen/Passes/EcoGCPrepare.cpp`

In `processBlock`, before calling `setGCRoots`, add a debug-only assertion:

```cpp
#ifndef NDEBUG
    // Verify front-end roots are a subset of liveness-computed roots.
    ValueRange oldRoots = carrier.getGCRoots();
    llvm::DenseSet<Value> computedSet(newRoots.begin(), newRoots.end());
    for (Value v : oldRoots) {
        if (!computedSet.contains(v)) {
            LLVM_DEBUG(llvm::dbgs()
                << "WARNING: front-end root not in liveness set: "
                << v << " at " << *carrier.getOperation() << "\n");
        }
    }
#endif
```

This is a **migration safety net**. Once confident, it can be removed. Pure replace is the production behavior — `carrier.setGCRoots(computedRoots)` overwrites unconditionally.

### Step 5: Add LLVM_DEBUG instrumentation

**File**: `runtime/src/codegen/Passes/EcoGCPrepare.cpp`

Add `#include "llvm/Support/Debug.h"` and `#define DEBUG_TYPE "eco-gc-prepare"`.

In `computeLiveRoots` or at the `setGCRoots` call site:

```cpp
LLVM_DEBUG({
    llvm::dbgs() << "EcoGCPrepare: " << op->getName()
                 << " in " << func.getName()
                 << " at " << op->getLoc()
                 << " — " << roots.size() << " roots: [";
    for (auto v : roots)
        llvm::dbgs() << " " << v;
    llvm::dbgs() << " ]\n";
});
```

Critical for validating that back-edge safepoints see loop-state block arguments.

### Step 6: Update SafepointOp description (TableGen)

**File**: `runtime/src/codegen/Ops.td` (around line 1191)

Update the description to clarify that operands are recomputed by EcoGCPrepare:

```tablegen
let description = [{
    GC safepoint operation. Marks a point where garbage collection can
    safely occur.

    The operands are eco.value roots that must be tracked across this
    safepoint. They are initially populated by the front-end
    (emitSafepoint in Expr.elm), then recomputed by EcoGCPrepare via
    SSA liveness analysis.

    During EcoToLLVM lowering, this becomes an llvm.experimental.gc.statepoint
    with gc.relocate operations for each live pointer. Downstream SSA uses
    of each operand are rewritten to use the relocated value via
    replaceAllUsesExcept.
}];
```

### Step 7: Update emitSafepoint comment (Elm front-end)

**File**: `compiler/src/Compiler/Generate/MLIR/Expr.elm` (lines 94-100)

Update the docstring only (no semantic change):

```elm
{-| Emit a GC safepoint op at this point in the IR.

The operands are a conservative set of live eco.value variables from
the front-end context (Ctx.liveEcoValueVars). EcoGCPrepare will later
recompute the final GC root set via SSA liveness analysis, so
correctness does not depend on this list being complete.
-}
```

### Step 8: Update Passes.h comment

**File**: `runtime/src/codegen/Passes.h` (lines 63-68)

```cpp
// Computes GC root sets for all GCRootCarrier ops (allocations, calls,
// safepoints, PAP ops, construct ops) via SSA liveness analysis.
// Groups adjacent allocations. Must run after all Eco->Eco transformations
// and control flow lowering (including SCF->CF), before EcoToLLVM.
```

### Step 9: Pipeline ordering (verified — no change needed)

**File**: `runtime/src/codegen/EcoPipeline.cpp` (lines 67-86)

Actual pipeline order:
```
JoinpointNormalization → EcoControlFlowToSCF → Canonicalizer → EcoGCPrepare → BFToLLVM → EcoToLLVM → SCFToControlFlow → ...
```

SCF ops (`scf.while`, `scf.if`) are present when EcoGCPrepare runs. MLIR's `Liveness` analysis handles regions correctly (fixpoint iteration over all attached regions). No pipeline reordering needed.

### Step 10: Testing

1. **MLIR tests** in `test/codegen/`:
   - `gc_liveness_safepoint_loop.mlir`: Tail-recursive loop with `eco.safepoint` before a back-edge `cf.br`. After EcoGCPrepare, verify roots include loop-state block arguments.
   - `gc_liveness_cross_block.mlir`: Safepoint in a block where live values are defined in a dominating block. Verify cross-block roots are captured.
   - `gc_liveness_alloc_group.mlir`: Verify alloc-grouping behavior is preserved (group leader gets roots, members get `eco.gc_group_member`).

   Use `// RUN: ecoc -emit=mlir-llvm` (or equivalent driver mode) and `// CHECK:` lines to assert the transformed IR contains expected roots.

2. **E2E GC stress tests**:
   - Run `cmake --build build --target full`.
   - Specifically target deep tail-recursive loops with allocations to verify the original crash is fixed.

3. **Optional validation**: Temporarily change `emitSafepoint` in Expr.elm to emit `[]` operands. If E2E tests still pass, this proves the backend is fully authoritative. Revert after validation.

---

## Files Changed

| File | Change | Type |
|------|--------|------|
| `CMakeLists.txt` (codegen library) | Add `MLIRAnalysis` link dependency | Build |
| `runtime/src/codegen/Passes/EcoGCPrepare.cpp` | Replace `computeLiveEcoValues` with `computeLiveRoots` using MLIR `Liveness`; add debug assertion and `LLVM_DEBUG` instrumentation | Core |
| `runtime/src/codegen/Ops.td` | Update SafepointOp description | Doc |
| `runtime/src/codegen/Passes.h` | Update comment | Doc |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Update emitSafepoint docstring | Doc |
| `ecoc.cpp` (or pipeline driver) | Verify pass ordering (no change expected) | Verification |
| `test/codegen/*.mlir` (new files) | MLIR tests for liveness-based roots | Test |

---

## Resolved Design Decisions

### D1: Liveness API — candidate set + `isDeadAfter`

Use `Liveness::isDeadAfter` over a candidate set:
- Candidates = block arguments + values defined before the carrier op in the block + `liveIn(block)`.
- Filter: `!isDeadAfter(v, op)` and `isEcoValue(v)`.

`currentlyLiveValues(op)` is not a public API. The candidate-set pattern matches other MLIR passes (e.g. buffer deallocation) and gives good performance.

### D2: Live-after semantics

Root set = values live **after** the safepoint op. Values only used *by* the op itself (not after) are excluded — the statepoint rewrites uses inside the op via relocates, and there's nothing to relocate beyond that point. Matches LLVM's statepoint GC-liveness definition.

### D3: Pure replace, not union

`carrier.setGCRoots(computedRoots)` overwrites unconditionally. The SSA liveness analysis is strictly more complete than the front-end heuristic. A debug assertion checks `frontEndRoots ⊆ computedRoots` during migration; can be removed once confident.

### D4: Alloc grouping — orthogonal

Grouping adjacent allocations under a single safepoint is preserved unchanged. Roots computed at the group leader (first op) are conservative: any value live across any grouped allocation is live after the first one. Switching to SSA-based liveness doesn't invalidate this.

### D5: Pipeline ordering — EcoGCPrepare runs WITH SCF ops present

**Corrected after inspecting `EcoPipeline.cpp`**: The actual pipeline order is:
```
JoinpointNormalization → EcoControlFlowToSCF → Canonicalizer → EcoGCPrepare → BFToLLVM → EcoToLLVM → SCFToControlFlow → ...
```
`SCFToControlFlow` runs *after* EcoGCPrepare, so `scf.while`/`scf.if` ops ARE present when the pass runs. MLIR's `Liveness` analysis supports regions (it iterates over all attached regions and computes fixpoints), so this is handled correctly. No pipeline reordering is needed.

### D6: Performance — acceptable

`Liveness` is computed once per function (O(V*B) fixpoint). The old heuristic was O(V*ops) per carrier op. For Elm-scale functions this is fine. Optimize only if profiling shows regression.

### D7: CMake dependency

`MLIRAnalysis` must be added to `target_link_libraries` for the library compiling `EcoGCPrepare.cpp`.

### D8: Test location

Tests go in `test/codegen/` as `.mlir` files with `// RUN:` + `// CHECK:` directives, using the existing `EcoRunner`/`ecoc` test harness.
