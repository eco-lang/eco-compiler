# Plan: ECO PAP Simplify Pass Implementation

## Overview

This plan implements **Variant B** from `design_docs/eco-dialect-simplifier.md`: an MLIR-level ECO dialect simplifier pass that optimizes partial application (PAP) patterns before lowering to LLVM.

## Goal

Eliminate unnecessary closure allocations and runtime calls by:
1. Converting saturated `papCreate + papExtend` patterns to direct calls
2. Fusing chains of `papExtend` operations
3. Removing dead closure allocations via canonical DCE

## Background: Current Implementation

### PAP Operations (from `runtime/src/codegen/Ops.td`)

**`eco.papCreate`**:
```mlir
%closure = eco.papCreate @function(%captured...) {
  arity = A : i64,
  num_captured = C : i64,
  unboxed_bitmap = B : i64
} : (types...) -> !eco.value
```

**`eco.papExtend`**:
```mlir
%result = eco.papExtend %closure(%newargs...) {
  remaining_arity = K : i64,
  newargs_unboxed_bitmap = B : i64
} : !eco.value, (types...) -> result_type
```

**Saturation condition**: `remaining_arity == newargs.size()`

### Current Pipeline (`runtime/src/codegen/EcoPipeline.cpp`)
```cpp
void buildEcoToEcoPipeline(PassManager &pm) {
    pm.addPass(eco::createRCEliminationPass());
    pm.addPass(eco::createUndefinedFunctionPass());
}
```

The new pass will be inserted between these two passes.

---

## Implementation Steps

### Step 1: Create the Pass File

**File:** `runtime/src/codegen/Passes/EcoPAPSimplify.cpp` *(new)*

```cpp
//===- EcoPAPSimplify.cpp - PAP optimization pass -------------------------===//
//
// This pass optimizes partial application patterns in the ECO dialect:
// - Converts saturated papCreate+papExtend to direct calls (P1)
// - Fuses papExtend chains (P2)
// - Enables DCE of unused closures (P3)
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

using namespace mlir;
using namespace eco;
```

Implement two rewrite patterns (P3 is handled by MLIR's DCE):

#### Pattern P1: Saturated PAP to Direct Call

**Match:**
- `%c = eco.papCreate @f(%captured...) { arity = A, num_captured = C }`
- `%r = eco.papExtend %c(%newArgs...) { remaining_arity = K }`
- Where `K == newArgs.size()` (saturated) AND `%c.hasOneUse()`

**Rewrite to:**
- `%r = eco.call @f(%captured..., %newArgs...) : (...) -> <same result types as papExtend>`

**Key implementation details:**

1. **Find the papCreate**: Use `op.getClosure().getDefiningOp<PapCreateOp>()`
2. **Check single use**: `op.getClosure().hasOneUse()` for safety
3. **Build operand list**: Concatenate `captured` from papCreate + `newargs` from papExtend
4. **Preserve result types exactly**: Set replacement `eco.call` results to `papExtend.getResultTypes()` - do NOT force `!eco.value`
5. **Set callee attribute**: Use the function symbol from papCreate

```cpp
struct SaturatedPapToCallPattern : public OpRewritePattern<PapExtendOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(PapExtendOp extendOp,
                                  PatternRewriter &rewriter) const override {
        // Check saturation
        int64_t remainingArity = extendOp.getRemainingArity();
        auto newargs = extendOp.getNewargs();
        if (static_cast<int64_t>(newargs.size()) != remainingArity)
            return failure();  // Not saturated

        // Find defining papCreate
        auto createOp = extendOp.getClosure().getDefiningOp<PapCreateOp>();
        if (!createOp)
            return failure();  // Closure not from papCreate

        // Check single use
        if (!extendOp.getClosure().hasOneUse())
            return failure();  // Closure used elsewhere

        // Build combined operand list: captured + newargs
        SmallVector<Value> allOperands;
        allOperands.append(createOp.getCaptured().begin(),
                          createOp.getCaptured().end());
        allOperands.append(newargs.begin(), newargs.end());

        // Create direct call with EXACT same result types as papExtend
        auto callOp = rewriter.create<CallOp>(
            extendOp.getLoc(),
            extendOp.getResultTypes(),  // Preserve result types exactly
            createOp.getFunction(),     // callee
            allOperands);

        rewriter.replaceOp(extendOp, callOp.getResults());
        // papCreate will be DCE'd since it now has no uses
        return success();
    }
};
```

#### Pattern P2: papExtend Chain Fusion

**Match:**
- `%c1 = eco.papExtend %c0(%a...) { remaining_arity = K1 }` (NOT saturated)
- `%c2 = eco.papExtend %c1(%b...) { remaining_arity = K2 }`
- Where `%c1.hasOneUse()` AND first extend is NOT saturated

**Rewrite to:**
- `%c2 = eco.papExtend %c0(%a..., %b...) { remaining_arity = K1, newargs_unboxed_bitmap = <computed> }`

**Key implementation details:**

1. **remaining_arity**: Use `K1` (the arity before first application) for the fused op
2. **Compute newargs_unboxed_bitmap from SSA types**: Don't shift/OR existing bitmaps. Instead, iterate over the concatenated newargs and set bits based on whether each operand's type is NOT `!eco.value` (i.e., is an unboxable primitive). This matches how codegen computes bitmaps and is more robust.

```cpp
struct FusePapExtendChainPattern : public OpRewritePattern<PapExtendOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(PapExtendOp extendOp,
                                  PatternRewriter &rewriter) const override {
        // Find defining papExtend (chain case)
        auto prevExtend = extendOp.getClosure().getDefiningOp<PapExtendOp>();
        if (!prevExtend)
            return failure();  // Not a chain

        // Check single use of intermediate closure
        if (!extendOp.getClosure().hasOneUse())
            return failure();

        // Check prev extend is NOT saturated (otherwise P1 would apply)
        int64_t prevRemaining = prevExtend.getRemainingArity();
        if (static_cast<int64_t>(prevExtend.getNewargs().size()) == prevRemaining)
            return failure();

        // Build fused newargs: prev.newargs + this.newargs
        SmallVector<Value> fusedNewargs;
        fusedNewargs.append(prevExtend.getNewargs().begin(),
                           prevExtend.getNewargs().end());
        fusedNewargs.append(extendOp.getNewargs().begin(),
                           extendOp.getNewargs().end());

        // Compute bitmap from SSA types (source-of-truth approach)
        uint64_t fusedBitmap = 0;
        for (size_t i = 0; i < fusedNewargs.size(); ++i) {
            if (!isa<ValueType>(fusedNewargs[i].getType())) {
                fusedBitmap |= (1ULL << i);
            }
        }

        // Create fused papExtend
        auto fusedOp = rewriter.create<PapExtendOp>(
            extendOp.getLoc(),
            extendOp.getResultTypes(),           // Preserve result types
            prevExtend.getClosure(),             // Original closure
            fusedNewargs,
            prevExtend.getRemainingArity(),      // Use K1 (arity before first apply)
            fusedBitmap);

        rewriter.replaceOp(extendOp, fusedOp.getResult());
        // prevExtend will be DCE'd
        return success();
    }
};
```

#### Pattern P3: Dead Closure Elimination

Rely on MLIR's canonical DCE. Both `PapCreateOp` and `PapExtendOp` are effectively pure (allocation-only side effects), so MLIR's infrastructure can safely remove them when their results are unused after P1/P2 rewrites.

#### Pass Structure

```cpp
struct EcoPAPSimplifyPass
    : public PassWrapper<EcoPAPSimplifyPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoPAPSimplifyPass)

    StringRef getArgument() const override { return "eco-pap-simplify"; }
    StringRef getDescription() const override {
        return "Optimize PAP patterns: saturated->call, chain fusion";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        MLIRContext *ctx = &getContext();

        RewritePatternSet patterns(ctx);
        patterns.add<SaturatedPapToCallPattern>(ctx);
        patterns.add<FusePapExtendChainPattern>(ctx);

        if (failed(applyPatternsAndFoldGreedily(module, std::move(patterns))))
            signalPassFailure();
    }
};

std::unique_ptr<Pass> eco::createEcoPAPSimplifyPass() {
    return std::make_unique<EcoPAPSimplifyPass>();
}
```

### Step 2: Register the Pass

**File:** `runtime/src/codegen/Passes.h` *(edit)*

Add declaration after the existing Stage 1 passes (around line 37):

```cpp
// Optimizes partial application patterns:
// - Converts saturated papCreate+papExtend to direct calls (P1)
// - Fuses papExtend chains (P2)
// - Enables DCE of unused closures (P3)
std::unique_ptr<mlir::Pass> createEcoPAPSimplifyPass();
```

### Step 3: Update CMakeLists.txt

**File:** `runtime/src/codegen/CMakeLists.txt` *(edit)*

Add the new file to the `EcoPasses` library (around line 183):

```cmake
add_mlir_library(EcoPasses
    Passes/RCElimination.cpp
    Passes/EcoPAPSimplify.cpp  # <-- Add this line
    Passes/JoinpointNormalization.cpp
    ...
```

### Step 4: Insert Pass into Pipeline

**File:** `runtime/src/codegen/EcoPipeline.cpp` *(edit)*

Modify `buildEcoToEcoPipeline()` to include the new pass:

```cpp
void buildEcoToEcoPipeline(PassManager &pm) {
    // Stage 1: Eco -> Eco transformations.
    pm.addPass(eco::createRCEliminationPass());

    // PAP simplification: fuse closures, convert saturated PAPs to direct calls
    pm.addPass(eco::createEcoPAPSimplifyPass());

    // Run canonicalize to clean up dead ops after PAP simplification
    pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());

    // Generate external declarations for undefined functions
    pm.addPass(eco::createUndefinedFunctionPass());
}
```

### Step 5: Add Regression Tests

**File:** `test/codegen/pap_simplify_saturated_to_call.mlir` *(new)*

Test P1: papCreate + saturated papExtend becomes direct call.

```mlir
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test that saturated papCreate+papExtend is optimized to a direct call.
// The optimization should eliminate closure allocation.

module {
  func.func @add(%a: i64, %b: i64) -> i64 {
    %sum = eco.int.add %a, %b : i64
    eco.return %sum : i64
  }

  func.func @main() -> i64 {
    %c5 = arith.constant 5 : i64
    %c7 = arith.constant 7 : i64

    // Create PAP with one captured arg
    %pap = "eco.papCreate"(%c5) {
      function = @add,
      arity = 2 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64) -> !eco.value

    // Saturate with second arg - should become: eco.call @add(%c5, %c7)
    %result = "eco.papExtend"(%pap, %c7) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    eco.dbg %result : i64
    // CHECK: [eco.dbg] 12

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
```

**File:** `test/codegen/pap_simplify_chain_fusion.mlir` *(new)*

Test P2: papExtend chain fusion.

```mlir
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test that papExtend chains are fused when intermediate results have single use.

module {
  func.func @add3(%a: i64, %b: i64, %c: i64) -> i64 {
    %ab = eco.int.add %a, %b : i64
    %abc = eco.int.add %ab, %c : i64
    eco.return %abc : i64
  }

  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64

    // Create PAP with one captured arg
    %pap = "eco.papCreate"(%c1) {
      function = @add3,
      arity = 3 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64) -> !eco.value

    // First extend (partial) - remaining 2, applying 1
    %pap2 = "eco.papExtend"(%pap, %c2) {
      remaining_arity = 2 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> !eco.value

    // Second extend (saturates) - chain should be fused then converted to call
    %result = "eco.papExtend"(%pap2, %c3) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    eco.dbg %result : i64
    // CHECK: [eco.dbg] 6

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
```

**File:** `test/codegen/pap_simplify_multi_use_no_transform.mlir` *(new)*

Test that multi-use closures are NOT transformed (safety check).

```mlir
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test that closures with multiple uses are NOT incorrectly optimized.

module {
  func.func @add(%a: i64, %b: i64) -> i64 {
    %sum = eco.int.add %a, %b : i64
    eco.return %sum : i64
  }

  func.func @main() -> i64 {
    %c5 = arith.constant 5 : i64
    %c3 = arith.constant 3 : i64
    %c7 = arith.constant 7 : i64

    // Create PAP - will be used TWICE
    %pap = "eco.papCreate"(%c5) {
      function = @add,
      arity = 2 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64) -> !eco.value

    // Use 1: 5 + 3 = 8
    %r1 = "eco.papExtend"(%pap, %c3) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    // Use 2: 5 + 7 = 12
    %r2 = "eco.papExtend"(%pap, %c7) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    eco.dbg %r1 : i64
    eco.dbg %r2 : i64
    // CHECK: [eco.dbg] 8
    // CHECK: [eco.dbg] 12

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
```

---

## Summary of Changes

| File | Change Type | Description |
|------|-------------|-------------|
| `runtime/src/codegen/Passes/EcoPAPSimplify.cpp` | NEW | Pass implementation with P1, P2 patterns |
| `runtime/src/codegen/Passes.h` | EDIT | Add `createEcoPAPSimplifyPass()` declaration |
| `runtime/src/codegen/CMakeLists.txt` | EDIT | Add new pass file to build |
| `runtime/src/codegen/EcoPipeline.cpp` | EDIT | Insert pass into pipeline |
| `test/codegen/pap_simplify_saturated_to_call.mlir` | NEW | Test for P1 |
| `test/codegen/pap_simplify_chain_fusion.mlir` | NEW | Test for P2 |
| `test/codegen/pap_simplify_multi_use_no_transform.mlir` | NEW | Safety test |

---

## Design Decisions (Based on Clarification)

### 1. Result Type Handling (P1)

**Decision:** Preserve exact result types from `papExtend` - do NOT force `!eco.value`.

**Rationale:**
- `eco.call` has variadic results (`outs Variadic<Eco_AnyValue>`) supporting both `!eco.value` and primitives like `i64`
- `eco.papExtend` can return typed results (e.g., `i64`) as shown in existing tests
- The pass should be robust to both strict (`!eco.value` only) and relaxed (typed) styles

### 2. Unboxed Bitmap Merging (P2)

**Decision:** Compute fused `newargs_unboxed_bitmap` from SSA operand types, not by shifting/OR-ing existing bitmaps.

**Rationale:**
- Matches how codegen computes bitmaps (inspects SSA types, sets bits for non-`!eco.value` types)
- More robust than arithmetic on existing bitmaps
- Aligns with invariant expectations (CGEN_003 style)
- Runtime handles captured bitmap merging separately

### 3. CallOpInterface / MLIR Inliner

**Decision:** Defer to future work.

**Rationale:**
- P1/P2 deliver the core wins (eliminating closure overhead) without inlining
- `CallOpInterface` is orthogonal work teaching MLIR to reason about `eco.call`
- Staged approach: ship P1/P2/P3, measure, then consider inliner

### 4. Multi-Result Functions

**Decision:** Don't assume single result - preserve result list exactly.

**Rationale:**
- `eco.call` is defined with variadic results
- Implementation uses `getResultTypes()` (plural) to handle any arity
- Future-proofs against potential multi-return ops

### 5. `_operand_types` Attribute

**Decision:** Pass does not need to handle this attribute.

**Rationale:**
- `_operand_types` is only used in Elm frontend for codegen verification
- C++ lowering code uses SSA operand types directly (verified via grep)
- No runtime dependency on this attribute

---

## Remaining Questions

**None** - all clarifications have been addressed.

---

## Assumptions

1. **Single-use check is sufficient**: `hasOneUse()` guarantees safe transformation due to SSA dominance
2. **PapCreateOp/PapExtendOp are effectively pure**: Allocation-only side effects, safe for DCE
3. **Pattern application order**: Greedy pattern rewriter will apply P2 (fusion) before P1 (saturated->call) when both match, which is the desired behavior for chains
4. **Existing tests continue to pass**: The optimization is semantics-preserving; existing PAP tests should still produce correct results
