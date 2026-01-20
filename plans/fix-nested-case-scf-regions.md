# Plan 2 — Fix nested cases causing invalid SCF regions ("expects 0 or 1 blocks")

## Problem

MLIR structured control flow operations (`scf.if` and `scf.index_switch`) require each of their regions to have **exactly one block**. The failure `scf.if op expects region #0 to have 0 or 1 blocks` occurs when the EcoToLLVM pass processes an `eco.case` that is nested inside an SCF region.

### SCF Region Requirements

Both `scf.if` and `scf.index_switch` have the same structural requirement — each region must contain exactly one block. This is fundamental to SCF's design; it represents structured, high-level control flow that can be easily reasoned about and optimized:

```mlir
scf.if %cond {
  ^single_block:    // MUST be exactly one block
    ...
    scf.yield %result
}

scf.index_switch %idx
case 0 {
  ^single_block:    // MUST be exactly one block
    ...
    scf.yield %result
}
case 1 {
  ^single_block:    // MUST be exactly one block
    ...
    scf.yield %result
}
```

This means the problem is **not specific to `scf.if`** — any `eco.case` nested inside ANY SCF region (whether `scf.if` or `scf.index_switch`) will fail when `CaseOpLowering` tries to create multiple blocks.

### Root Cause Analysis

The issue arises from the interaction between two passes:

1. **EcoControlFlowToSCF pass**: Correctly transforms the OUTER `eco.case` to `scf.if`, cloning the inner `eco.case` into `scf.if`'s then region. The inner case is NOT transformed because it's not in terminal position (followed by `eco.constant`, not `eco.return` or `scf.yield`).

2. **EcoToLLVM pass**: Later, `CaseOpLowering` processes the inner `eco.case` which is now inside `scf.if`'s then region. The pattern creates NEW BLOCKS in the parent region:

```cpp
// EcoToLLVMControlFlow.cpp lines 573, 582-587
Block *currentBlock = op->getBlock();           // scf.if's then block
Region *parentRegion = currentBlock->getParent(); // scf.if's then region

Block *mergeBlock = rewriter.createBlock(parentRegion);  // PROBLEM: adds block to scf.if region!

for (size_t i = 0; i < alternatives.size(); ++i) {
    Block *caseBlock = rewriter.createBlock(parentRegion);  // More blocks added!
    ...
}
```

This violates `scf.if`'s single-block region requirement.

### Sequence of Events

For `CaseListTest.elm` with nested list pattern matching:

```
Initial IR:
  outer_case {
    alt0: { "empty"; eco.return }
    alt1: {
      inner_case { "one"; eco.return }, { "many"; eco.return }
      eco.constant Unit
      eco.return
    }
  }
  eco.return

After SCF pass:
  scf.if {
    then_region {
      block0 {           // single block
        inner_case {...} // still eco.case, not transformed
        eco.constant
        scf.yield
      }
    }
    else_region {
      block0 { "empty"; scf.yield }
    }
  }
  eco.return

During EcoToLLVM pass (CaseOpLowering on inner_case):
  scf.if {
    then_region {
      block0 { ... cf.switch ... }   // original block, modified
      block1 { ... }                  // NEW - case block for alt0
      block2 { ... }                  // NEW - case block for alt1
      block3 { ... }                  // NEW - merge block
    }
    ...
  }

  ERROR: scf.if region has 4 blocks, expected 0 or 1
```

### Same Problem with scf.index_switch Inside scf.index_switch

The problem would be identical if an `eco.case` lowered to `scf.index_switch` contained a nested `eco.case`:

```
scf.index_switch %outer_idx
case 0 {
  ^block0:
    eco.case %inner_cond {         // <- When CaseOpLowering processes this...
      alt0: { ... }
      alt1: { ... }
    }
    scf.yield
}

After CaseOpLowering runs:

scf.index_switch %outer_idx
case 0 {
  ^block0:    // original block
    cf.switch ...
  ^block1:    // NEW - violates single-block requirement!
    ...
  ^block2:    // NEW - violates single-block requirement!
    ...
}

ERROR: scf.index_switch case region has 3 blocks, expected 1
```

The issue is that `CaseOpLowering` uses **CF-style lowering** (creating multiple basic blocks with explicit branches) inside **SCF-style regions** (which require single blocks with structured terminators). This is incompatible regardless of which SCF operation is the parent.

### Why Two-Phase Conversion Failed

An earlier approach tried to split the conversion into two phases:
1. Phase 1: Convert SCF → CF
2. Phase 2: Convert ECO → LLVM

This failed because **type conversion and structural conversion are tightly coupled**:

- SCF ops have `!eco.value` types
- SCF-to-CF creates CF ops that inherit those `!eco.value` types
- Phase 2 marks CF ops with `!eco.value` as illegal (needing type conversion)
- But the CF ops were created in Phase 1 without type conversion

The original single-pass design worked (partially) because within ONE dialect conversion, type conversion + SCF structural conversion + branch type conversion can interleave correctly.

---

## Design: Single dialect conversion with dynamic legality to defer `eco.case` while under SCF

### Key Idea

Use **dynamic legality** for `eco.case`:

- While an `eco.case` is nested under `scf.if` / `scf.index_switch`, treat it as *temporarily legal* (so the conversion driver will not try to rewrite it yet, and therefore won't record a "failed to legalize" on it).
- SCF ops are illegal, so they must be rewritten away.
- Once SCF is rewritten to CF, the same `eco.case` is now nested under CF blocks (no SCF parent), so it becomes illegal, and **then** `CaseOpLowering` runs safely (because it can create blocks in CFG regions).

This is exactly the kind of use case dynamic legality is designed for: "this op is legal only in some structural contexts".

### Why This Works

1. **Before SCF is eliminated**: Nested `eco.case` ops are *legal* and will not be visited as "must-rewrite". The conversion driver doesn't record a failed legalization attempt.

2. **After SCF→CF runs**: The *same* `eco.case` (or its clone moved into CF blocks) is now **not under SCF**, so the dynamic legality predicate returns false → it becomes illegal → the conversion must rewrite it → `CaseOpLowering` runs in a CFG region where it can safely create blocks.

3. **Type conversion coupling preserved**: Everything happens in one conversion, so SCF typing + structural lowering + branch typing + ECO lowering all interleave correctly.

---

## Required Code Changes

### 2A) `runtime/src/codegen/Passes/EcoToLLVM.cpp` — add dynamic legality for `eco.case`

**Where:** Immediately after line 147 (`target.addIllegalDialect<EcoDialect>();`).

**Change:** Add dynamic legality for `eco::CaseOp` that makes it temporarily legal when nested under SCF. In MLIR, `addDynamicallyLegalOp` for a specific op overrides dialect-level `addIllegalDialect`:

```cpp
// Mark all Eco dialect operations as illegal (to be lowered)
target.addIllegalDialect<EcoDialect>();

// Override for CaseOp: temporarily legal when nested under SCF.
// This defers CaseOpLowering until SCF regions are converted to CF,
// preventing the creation of multiple blocks inside SCF single-block regions.
target.addDynamicallyLegalOp<CaseOp>([](CaseOp op) {
    // If nested under SCF, treat as temporarily legal (don't convert yet)
    if (op->getParentOfType<scf::IfOp>() ||
        op->getParentOfType<scf::IndexSwitchOp>()) {
        return true;
    }
    // Otherwise, require conversion (illegal)
    return false;
});
```

### 2B) `runtime/src/codegen/Passes/EcoToLLVM.cpp` — make SCF dialect illegal

**Where:** Immediately after line 171 (`scf::populateSCFStructuralTypeConversionsAndLegality(...)`).

**Why after:** The `populateSCFStructuralTypeConversionsAndLegality` function internally marks SCF ops as dynamically legal. We call `addIllegalDialect` afterward to override this and ensure SCF ops MUST be eliminated (not just type-converted).

```cpp
// Add SCF structural type conversion patterns
scf::populateSCFStructuralTypeConversionsAndLegality(typeConverter, patterns, target);

// Override: SCF must be fully eliminated, not just type-converted.
// This ensures SCF-to-CF patterns run to completion.
target.addIllegalDialect<scf::SCFDialect>();

// Add SCF-to-CF lowering patterns
populateSCFToControlFlowConversionPatterns(patterns);
```

### 2C) `runtime/src/codegen/Passes/EcoToLLVM.cpp` — keep single conversion with all patterns

**Verify:** The pass already uses a SINGLE `applyPartialConversion` with ALL patterns. No change needed — just ensure this structure is preserved:

- `scf::populateSCFStructuralTypeConversionsAndLegality(...)` — handles SCF type conversion
- `populateSCFToControlFlowConversionPatterns(...)` — converts SCF to CF
- `populateBranchOpInterfaceTypeConversionPattern(...)` — type converts branch ops
- All ECO lowering patterns

Do NOT split into separate phases/conversions.

### 2D) `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp` — remove SCF parent check from CaseOpLowering

**Where:** `CaseOpLowering::matchAndRewrite` function.

**Change:** Remove any "return failure() when nested under SCF" guard:

```cpp
// REMOVE THIS:
if (op->getParentOfType<scf::IfOp>() || op->getParentOfType<scf::IndexSwitchOp>()) {
    return failure();
}
```

**Why:** Legality now controls *when* `CaseOpLowering` is invoked. The pattern should assume it is only called in a legal context (i.e., not under SCF).

**Optional debug assert:** If desired, keep an assert in debug builds as a sanity check, but don't return failure():

```cpp
#ifndef NDEBUG
assert(!op->getParentOfType<scf::IfOp>() &&
       !op->getParentOfType<scf::IndexSwitchOp>() &&
       "CaseOpLowering should not be invoked while nested under SCF");
#endif
```

### 2E) Add regression tests

Add test cases to ensure nested eco.case no longer breaks SCF regions:

#### `test/codegen/eco-case-nested-in-scf-if.mlir`

**Purpose:** Reproduce the exact failure mode: an `eco.case` inside `scf.if`'s region.

**Test outline:**
- Create `scf.if` with a single block region
- Put an `eco.case` inside that region
- Run the EcoToLLVM pass
- `// CHECK-NOT:` for the SCF verifier error
- `// CHECK:` that no `scf.if` remains and `eco.case` is lowered

#### `test/codegen/eco-case-nested-in-scf-index-switch.mlir`

**Purpose:** Same concept for `scf.index_switch`.

---

## Test Cases Affected

- CaseListTest.elm (nested bool cases for [], [_], _)
- CaseListThreeWayTest.elm (nested cases for [], [x], x::xs)
- CaseTupleTest.elm (nested cases for tuple patterns)
- CaseTripleTest.elm (nested cases for 3-tuple patterns)
- CaseDeeplyNestedTest.elm (3-level nested Maybe cases)
- CaseNestedTest.elm (2-level nested Maybe cases)

## Verification

After applying the fix, run:

```bash
TEST_FILTER=CaseList cmake --build build --target check
TEST_FILTER=CaseNested cmake --build build --target check
TEST_FILTER=CaseTuple cmake --build build --target check
```

All should pass without "expects 0 or 1 blocks" errors.

---

## Why This Design Works

1. **Single conversion preserves type coupling**: SCF typing + structural lowering + branch typing + ECO lowering all happen in one `applyPartialConversion`, allowing them to interleave correctly.

2. **Dynamic legality defers problematic patterns**: `eco.case` ops nested under SCF are "legal" (temporarily), so the conversion driver doesn't try to rewrite them and doesn't record failed legalization.

3. **SCF elimination triggers re-evaluation**: Once SCF-to-CF patterns convert `scf.if` to `cf.cond_br`, the `eco.case` (now in a CF block) is re-evaluated for legality. It's no longer under SCF, so it becomes illegal and must be converted.

4. **No two-phase type conversion issues**: Since everything is in one conversion, CF ops created by SCF-to-CF get their types converted in the same pass.

---

## Alternative Approaches Considered

1. **Two-phase conversion (SCF→CF then ECO→LLVM)** — Failed because type conversion and structural conversion are coupled. Phase 1 produces CF ops with `!eco.value` types that Phase 2 marks as illegal.

2. **Return `failure()` when nested under SCF** — Failed because `applyPartialConversion` doesn't retry. The framework records "failed to legalize" before SCF-to-CF runs.

3. **Greedy rewrite for SCF-to-CF** — Failed because greedy rewrite doesn't do type conversion, producing CF ops with unconverted types.

The dynamic legality approach is the correct MLIR-native solution for this problem.
