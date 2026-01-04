# Implementation Plan: eco.case with Eco_AnyValue Scrutinee

This plan implements the design in `design_docs/eco-case-any.md` to allow `eco.case` to operate directly on `i1` (Bool) scrutinees without boxing.

## Overview

**Goal**: Unify control flow for Bool pattern matching by using `eco.case` directly on `i1` values instead of falling back to `scf.if`. This removes the need to box Bool values just for pattern matching.

**Current State**:
- `eco.case` only accepts `!eco.value` (boxed heap pointer) as scrutinee
- Bool pattern matching (`generateBoolFanOut`, `generateChainGeneral`) uses `scf.if` directly
- This works but creates two parallel control-flow paths in the Elm codegen

**Target State**:
- `eco.case` accepts `Eco_AnyValue` (including `i1`) as scrutinee
- Bool pattern matching uses `eco.case %cond : i1`
- SCF lowering handles `i1` scrutinee by using the value directly as condition

---

## Implementation Steps

### Step 1: Update Dialect Definition (Ops.td)

**File**: `/work/runtime/src/codegen/Ops.td`

**Change** (line 146):
```tablegen
// Before:
Eco_Value:$scrutinee,

// After:
Eco_AnyValue:$scrutinee,
```

This allows `eco.case` to accept any Eco value type including `i1`, `i64`, `f64`, and `!eco.value`.

---

### Step 2: Update Verifier (EcoOps.cpp)

**File**: `/work/runtime/src/codegen/EcoOps.cpp`

**Add to `CaseOp::verify()`** (after line 29, before result types extraction):

```cpp
// Verify scrutinee type is allowed
Type scrutineeType = getScrutinee().getType();
if (!isa<eco::ValueType>(scrutineeType)) {
    // For non-eco.value scrutinees, only allow i1 (Bool)
    if (auto intType = dyn_cast<IntegerType>(scrutineeType)) {
        if (intType.getWidth() != 1) {
            return emitOpError("scrutinee must be !eco.value or i1, got ")
                   << scrutineeType;
        }
        // For i1 scrutinee, verify tags are only 0 or 1
        for (int64_t tag : getTags()) {
            if (tag != 0 && tag != 1) {
                return emitOpError("i1 scrutinee requires tags in {0, 1}, got ")
                       << tag;
            }
        }
    } else {
        return emitOpError("scrutinee must be !eco.value or i1, got ")
               << scrutineeType;
    }
}
```

**Required includes** (if not present):
```cpp
#include "mlir/IR/BuiltinTypes.h"  // for IntegerType
```

---

### Step 3: Update SCF Lowering (EcoControlFlowToSCF.cpp)

**File**: `/work/runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp`

#### 3.1 Add helper to detect i1 scrutinee

**Add after line 70** (after `getCaseResultTypes` helper):

```cpp
/// Check if the case op has an i1 (Bool) scrutinee.
bool hasI1Scrutinee(CaseOp op) {
    Type scrutineeType = op.getScrutinee().getType();
    if (auto intType = dyn_cast<IntegerType>(scrutineeType)) {
        return intType.getWidth() == 1;
    }
    return false;
}
```

#### 3.2 Modify `CaseToScfIfPattern` to handle i1 scrutinee

**In `CaseToScfIfPattern::matchAndRewrite`** (around line 133-145):

Replace the tag extraction and comparison code:
```cpp
// Before (lines 136-145):
// Create eco.get_tag to extract the constructor tag
auto tag = rewriter.create<GetTagOp>(loc, rewriter.getI32Type(),
                                     op.getScrutinee());

// Create comparison: tag == tags[1] (second alternative)
auto tagConstant = rewriter.create<arith::ConstantOp>(
    loc, rewriter.getI32IntegerAttr(tags[1]));
auto cond = rewriter.create<arith::CmpIOp>(
    loc, arith::CmpIPredicate::eq, tag, tagConstant);
```

With:
```cpp
// Compute condition based on scrutinee type
Value cond;
if (hasI1Scrutinee(op)) {
    // For i1 scrutinee: use the value directly as condition
    // Convention: tag 1 = True goes to alt1 (then), tag 0 = False goes to alt0 (else)
    // If tags[1] == 1, condition is the scrutinee directly
    // If tags[1] == 0, condition is negated
    if (tags[1] == 1) {
        cond = op.getScrutinee();
    } else {
        // tags[1] == 0: negate the condition
        auto trueConst = rewriter.create<arith::ConstantOp>(
            loc, rewriter.getI1Type(), rewriter.getIntegerAttr(rewriter.getI1Type(), 1));
        cond = rewriter.create<arith::XOrIOp>(loc, op.getScrutinee(), trueConst);
    }
} else {
    // For eco.value scrutinee: extract tag and compare
    auto tag = rewriter.create<GetTagOp>(loc, rewriter.getI32Type(),
                                         op.getScrutinee());
    auto tagConstant = rewriter.create<arith::ConstantOp>(
        loc, rewriter.getI32IntegerAttr(tags[1]));
    cond = rewriter.create<arith::CmpIOp>(
        loc, arith::CmpIPredicate::eq, tag, tagConstant);
}
```

#### 3.3 Modify `CaseToScfIndexSwitchPattern` to reject i1 scrutinee

**Add early return at the start of matchAndRewrite** (after line 247):

```cpp
// i1 scrutinee should use the 2-way pattern (scf.if), not index_switch
if (hasI1Scrutinee(op))
    return failure();
```

---

### Step 4: Update Elm Codegen (MLIR.elm)

**File**: `/work/compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

#### 4.1 Modify `generateBoolFanOut` to use `eco.case`

**Replace lines 3804-3847**:

```elm
{-| Handle Bool FanOut with eco.case on i1 scrutinee.
    eco.case now accepts i1 directly, lowered to scf.if by the SCF pass.
-}
generateBoolFanOut : Context -> Name.Name -> DT.Path -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateBoolFanOut ctx root path edges fallback resultTy =
    let
        -- Get the Bool value as i1 type
        ( pathOps, boolVar, ctx1 ) =
            generateDTPath ctx root path I1

        -- Find True and False branches
        ( trueBranch, falseBranch ) =
            findBoolBranches edges fallback

        -- Generate True branch (tag 1) with eco.return
        thenRes =
            generateDecider ctx1 root trueBranch resultTy

        thenRegion =
            mkRegionFromOps thenRes.ops

        -- Generate False branch (tag 0 or default) with eco.return
        elseRes =
            generateDecider thenRes.ctx root falseBranch resultTy

        elseRegion =
            mkRegionFromOps elseRes.ops

        -- eco.case on Bool: tag 1 for True, tag 0 for False
        -- Regions: [True region, False region] corresponding to tags [1, 0]
        ( ctx2, caseOp ) =
            ecoCase elseRes.ctx boolVar I1 [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
    in
    { ops = pathOps ++ [ caseOp ]
    , resultVar = boolVar  -- Dummy; control exits via eco.return inside regions
    , resultType = resultTy
    , ctx = ctx2
    }
```

#### 4.2 Modify `generateChainForBoolADT` to use `eco.case`

**Replace lines 3682-3723**:

```elm
{-| Special handling for direct Bool ADT pattern matching.
    For `case b of True -> X; False -> Y`, use eco.case with i1 scrutinee.
-}
generateChainForBoolADT : Context -> Name.Name -> DT.Path -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateChainForBoolADT ctx root path success failure resultTy =
    let
        -- Get the Bool value (i1 type)
        ( pathOps, boolVar, ctx1 ) =
            generateDTPath ctx root path I1

        -- Generate success branch (True) with eco.return
        thenRes =
            generateDecider ctx1 root success resultTy

        thenRegion =
            mkRegionFromOps thenRes.ops

        -- Generate failure branch (False) with eco.return
        elseRes =
            generateDecider thenRes.ctx root failure resultTy

        elseRegion =
            mkRegionFromOps elseRes.ops

        -- eco.case on Bool: tag 1 for True (success), tag 0 for False (failure)
        ( ctx2, caseOp ) =
            ecoCase elseRes.ctx boolVar I1 [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
    in
    { ops = pathOps ++ [ caseOp ]
    , resultVar = boolVar  -- Dummy; control exits via eco.return inside regions
    , resultType = resultTy
    , ctx = ctx2
    }
```

#### 4.3 Modify `generateChainGeneral` to use `eco.case`

**Replace lines 3729-3768**:

```elm
{-| General case for Chain node: compute boolean condition and dispatch.
    Uses eco.case with i1 scrutinee (lowered to scf.if by the SCF pass).
-}
generateChainGeneral : Context -> Name.Name -> List ( DT.Path, DT.Test ) -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateChainGeneral ctx root testChain success failure resultTy =
    let
        -- Compute the boolean condition (produces i1)
        ( condOps, condVar, ctx1 ) =
            generateChainCondition ctx root testChain

        -- Generate success branch with eco.return
        thenRes =
            generateDecider ctx1 root success resultTy

        thenRegion =
            mkRegionFromOps thenRes.ops

        -- Generate failure branch with eco.return
        elseRes =
            generateDecider thenRes.ctx root failure resultTy

        elseRegion =
            mkRegionFromOps elseRes.ops

        -- eco.case on Bool: tag 1 for True (success), tag 0 for False (failure)
        ( ctx2, caseOp ) =
            ecoCase elseRes.ctx condVar I1 [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
    in
    { ops = condOps ++ [ caseOp ]
    , resultVar = condVar  -- Dummy; control exits via eco.return inside regions
    , resultType = resultTy
    , ctx = ctx2
    }
```

#### 4.4 Update `generateFanOutGeneral` comment

**Update comment at line 3873-3874**:

```elm
{-| General case FanOut using eco.case (for non-Bool ADT patterns).
    eco.case accepts !eco.value scrutinee; for Bool patterns, generateBoolFanOut uses i1.
-}
```

#### 4.5 Leave `generateIf` unchanged

Per design decision D1, `generateIf` stays on `scf.if`. No changes needed.

---

### Step 5: Cleanup

After verifying the changes work:

1. **Remove dead SCF-based Decider functions** (per decision D2):
   - `generateDeciderForScfIf` (line ~3543)
   - `generateLeafForScfIf` (line ~3560)
   - `generateChainForScfIf` (line ~3600)
   - `generateFanOutForScfIf` (line ~3649)

2. **Keep `scfIf` and `scfYield`** - still needed by `generateIf` (per D3)

3. **Update outdated comments** throughout `MLIR.elm`:
   - Remove/update comments saying "eco.case uses eco.get_tag which dereferences the value as a pointer"
   - Update to reflect that eco.case now accepts i1 directly

---

## Verification Plan

### Unit Tests

1. **Existing tests should pass**:
   - `test/codegen/scf_if_pure_case_test.mlir`
   - All `CaseBoolTest.elm`, `CaseIntTest.elm`, `CaseListTest.elm` tests

2. **Add new MLIR tests** for i1 scrutinee:
   - `test/codegen/eco_case_bool_test.mlir` with direct `eco.case %b : i1` syntax

### Integration Tests

Run the full test suite:
```bash
./build/test/test -n 100
```

### Manual Verification

Compile a Bool pattern match and inspect MLIR:
```bash
./build/ecor emit-mlir test/elm/src/CaseBoolTest.elm
```

Expected output should show `eco.case %x : i1` instead of `scf.if`.

---

## Design Decisions (Resolved)

### D1: Keep `generateIf` using `scf.if`

**Decision**: Keep `generateIf` on `scf.if`, do NOT switch to `eco.case`.

**Rationale**:
- `MonoIf` is an *expression* that can appear in non-tail position. We need an SSA value back.
- `scf.if` models this naturally: explicit SSA results with `scf.yield` in each branch.
- `eco.case` is control-only: regions end in `eco.return`/`eco.jump` without producing SSA results. Using it for non-tail `if` would require extra joinpoints or dummy continuations.

**Boundary**:
- SCF is the frontend representation for local conditional expressions (`generateIf`)
- Eco control-flow ops are for Elm `case` pattern matches and joinpoints

### D2: Remove `generateDeciderForScfIf` after migration

**Decision**: Delete `generateDeciderForScfIf` and related helpers after switching Bool paths to `eco.case`.

**Rationale**:
- After Bool FanOut/Chain use `eco.case`, they call `generateDecider` directly
- `generateDeciderForScfIf` becomes dead code
- All Decider paths should use `generateDecider` (eco), not SCF

**Action**: After implementing Bool paths with `eco.case`, search for `generateDeciderForScfIf`. If unused, delete it.

### D3: Keep `scfIf`/`scfYield` for `generateIf`

**Decision**: Keep these helpers since `generateIf` stays on `scf.if`.

**Note**: After switching Bool FanOut/Chain to `eco.case`, the only user of `scfIf`/`scfYield` will be `generateIf`.

### D4: Tag ordering for Bool

**Decision**: Use explicit tags [1, 0] with two regions.
- Tag 1 = True (first region)
- Tag 0 = False (second region)

This is clearer than using a default fallback and matches existing code structure.

---

## Risk Assessment

**Low Risk**:
- Dialect change is additive (accepts more types)
- Verifier change adds stricter validation for i1
- SCF lowering change is in a well-isolated pattern

**Medium Risk**:
- Elm codegen changes touch multiple functions
- Need to ensure `generateDecider` produces correct `eco.return` terminators
- Need to verify `mkRegionFromOps` handles terminator correctly

**Mitigation**:
- Incremental testing after each step
- Keep old code paths temporarily for A/B comparison
- Run full test suite at each step

---

## Implementation Order

1. **Ops.td** - Simple one-line change
2. **EcoOps.cpp verifier** - Add type checking
3. **EcoControlFlowToSCF.cpp** - Add i1 handling to patterns
4. **Build and test C++ changes** - `cmake --build build && ./build/test/test`
5. **MLIR.elm** - Update Bool paths to use eco.case
6. **Test full pipeline** - `./build/ecor compile test/elm/src/CaseBoolTest.elm`
7. **Cleanup** - Remove unused code, update comments
