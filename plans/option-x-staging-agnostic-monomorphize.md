# Option X: Staging-Agnostic Monomorphize for Closures and Tail Functions

## Overview

This plan extends the staging system to ensure **every function value** (both `MonoClosure` and `MonoTailFunc`) satisfies the GOPT_001 invariant after GlobalOpt:

> `length(params) == stageArity(type)`

Currently, closures and tail functions only have their types canonicalized when they participate in staging classes with `naturalSeg != canonicalSeg`. This plan ensures type canonicalization happens for **all** function producers, regardless of class membership.

### Key Insight: Inner Functions Must Also Be Canonical

When a wrapper is built (`naturalSeg != canonicalSeg`), the **inner** closure/tail function is still a real node in the mono graph with its own `params` and `type`. If we leave the inner node's type in curried form:
- The inner node violates GOPT_001
- Any passes/checks that inspect that inner node will see the mismatch

**Rule:** The inner closure/tail function must also have `canonType`, even when wrapped. The wrapper exists only to adapt segmentation/staging ABI, not to exempt the inner node from the invariant.

## Current State Analysis

### GraphBuilder.elm (lines 108-387)
- **Closures** (`MonoClosure`): Adds capture constraints but does NOT register the closure as a `NodeProducer` in the staging graph
- **Tail functions** (`MonoTailFunc` in `foldNode`, lines 51-90): Creates parameter slots but does NOT register as a `NodeProducer`

### Rewriter.elm
- **Closures** (`rewriteExpr`, lines 183-225):
  - `Nothing` case (no class): Returns `monoType` unchanged ❌
  - `naturalSeg == canonicalSeg` case: Returns `monoType` unchanged ❌
  - Only flattens type when `naturalSeg != canonicalSeg`

- **Tail functions** (`rewriteNode`, lines 93-168):
  - `Nothing` case: Returns `monoType` unchanged ❌
  - `naturalSeg == canonicalSeg` case: Returns `monoType` unchanged ❌
  - Only flattens type when `naturalSeg != canonicalSeg`

### wrapClosureToCanonical (lines 433-450)
- Currently passes `Mono.MonoClosure originalInfo originalBody originalType` to wrapper builder
- The inner closure retains `originalType` (curried form) ❌ violates GOPT_001

### ProducerInfo.elm (lines 38-88)
- Already computes `naturalSeg` and `totalArity` for both `MonoClosure` and `MonoTailFunc`
- This information is already available for all function producers

---

## Implementation Plan

### Step 1: flattenTypeToArity - Add Error for Invalid State

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm`
**Function:** `flattenTypeToArity` (lines 555-589)

**Change:** Make `allArgs.length < paramCount` a hard error instead of silently returning the type unchanged. This case indicates a broken mono graph (params/type mismatch).

```elm
-- BEFORE (line 583-589):
    else
        -- Fewer args than params - error case
        monoType

-- AFTER:
    else
        -- Fewer args than params - mono graph is inconsistent
        Debug.todo
            ("flattenTypeToArity: paramCount ("
                ++ String.fromInt targetArity
                ++ ") > number of flattened args ("
                ++ String.fromInt (List.length allArgs)
                ++ "); mono graph is inconsistent"
            )
```

**Rationale:** If `allArgs.length < paramCount`, the syntax says "this function has N parameters" but the type says "fewer than N argument slots." This is a hard inconsistency that should never happen in a well-formed mono graph. Silently returning the type unchanged would mask bugs and re-introduce exactly the kind of mismatch GOPT_001 is designed to detect.

### Step 2: GraphBuilder.elm - Register Closures as Producers

**File:** `compiler/src/Compiler/GlobalOpt/Staging/GraphBuilder.elm`
**Function:** `buildStagingGraphExpr` (lines 216-244, `MonoClosure` branch)

**Change:** Add `ensureNode (NodeProducer pid) sg0` before processing captures.

```elm
-- BEFORE (line 218-244):
Mono.MonoClosure closureInfo body _ ->
    let
        pid =
            ProducerClosure closureInfo.lambdaId

        sg1 =
            List.foldl
                (\( index, ( _, captureExpr, _ ) ) accSg -> ...)
                sg0
                (List.indexedMap Tuple.pair closureInfo.captures)
    in
    buildStagingGraphExpr body sg1 ctx0

-- AFTER:
Mono.MonoClosure closureInfo body _ ->
    let
        pid =
            ProducerClosure closureInfo.lambdaId

        -- Ensure the producer node exists in the staging graph
        ( _, sgWithProducer ) =
            ensureNode (NodeProducer pid) sg0

        sg1 =
            List.foldl
                (\( index, ( _, captureExpr, _ ) ) accSg -> ...)
                sgWithProducer  -- Changed from sg0
                (List.indexedMap Tuple.pair closureInfo.captures)
    in
    buildStagingGraphExpr body sg1 ctx0
```

### Step 3: GraphBuilder.elm - Register Tail Functions as Producers

**File:** `compiler/src/Compiler/GlobalOpt/Staging/GraphBuilder.elm`
**Function:** `foldNode` (lines 51-90, `MonoTailFunc` branch)

**Change:** Add `ensureNode (NodeProducer pid) sg` at the start.

```elm
-- BEFORE (line 57-81):
Mono.MonoTailFunc params body _ ->
    let
        ( sg1, ctx1 ) =
            List.foldl
                (\( index, ( _, ty ) ) ( accSg, accCtx ) -> ...)
                ( sg, ctx )
                (List.indexedMap Tuple.pair params)
    in
    buildStagingGraphExpr body sg1 ctx1

-- AFTER:
Mono.MonoTailFunc params body _ ->
    let
        pid =
            ProducerTailFunc nodeId

        -- Ensure the producer node exists in the staging graph
        ( _, sgWithProducer ) =
            ensureNode (NodeProducer pid) sg

        ( sg1, ctx1 ) =
            List.foldl
                (\( index, ( _, ty ) ) ( accSg, accCtx ) -> ...)
                ( sgWithProducer, ctx )  -- Changed from ( sg, ctx )
                (List.indexedMap Tuple.pair params)
    in
    buildStagingGraphExpr body sg1 ctx1
```

### Step 4: Rewriter.elm - Canonicalize Closure Types (All Branches)

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm`
**Function:** `rewriteExpr` (lines 183-225, `MonoClosure` branch)

**Change:** Compute `canonType` and use it in **all** cases, including when passing to `wrapClosureToCanonical`. The inner closure must satisfy GOPT_001 even when wrapped.

```elm
-- BEFORE:
Mono.MonoClosure closureInfo body monoType ->
    let
        pid = ProducerClosure closureInfo.lambdaId
        key = producerIdToKey pid
        maybeClassId = Dict.get identity key solution.producerClass
        ( newBody, ctx1 ) = rewriteExpr solution producerInfo body ctx0
    in
    case maybeClassId of
        Nothing ->
            ( Mono.MonoClosure closureInfo newBody monoType, ctx1 )

        Just classId ->
            let
                canonicalSeg = Dict.get identity classId solution.classSeg |> Maybe.withDefault []
                naturalSeg = Dict.get identity key producerInfo.naturalSeg |> Maybe.withDefault []
            in
            if naturalSeg == canonicalSeg then
                ( Mono.MonoClosure closureInfo newBody monoType, ctx1 )
            else
                wrapClosureToCanonical closureInfo newBody monoType canonicalSeg ctx1

-- AFTER:
Mono.MonoClosure closureInfo body monoType ->
    let
        pid = ProducerClosure closureInfo.lambdaId
        key = producerIdToKey pid
        maybeClassId = Dict.get identity key solution.producerClass
        ( newBody, ctx1 ) = rewriteExpr solution producerInfo body ctx0

        -- GOPT_001: Always compute canonical type for this closure
        paramCount = List.length closureInfo.params
        canonType = flattenTypeToArity paramCount monoType
    in
    case maybeClassId of
        Nothing ->
            -- No staging class: enforce GOPT_001
            ( Mono.MonoClosure closureInfo newBody canonType, ctx1 )

        Just classId ->
            let
                canonicalSeg = Dict.get identity classId solution.classSeg |> Maybe.withDefault []
                naturalSeg = Dict.get identity key producerInfo.naturalSeg |> Maybe.withDefault []
            in
            if naturalSeg == canonicalSeg then
                -- No wrapper needed: enforce GOPT_001
                ( Mono.MonoClosure closureInfo newBody canonType, ctx1 )
            else
                -- Wrapper needed: pass canonType so inner closure satisfies GOPT_001
                -- Pass monoType for segmentation derivation
                wrapClosureToCanonical closureInfo newBody monoType canonType canonicalSeg ctx1
```

### Step 5: Rewriter.elm - Update wrapClosureToCanonical Signature

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm`
**Function:** `wrapClosureToCanonical` (lines 433-450)

**Change:** Accept both `originalType` (for segmentation derivation) and `canonType` (for inner closure's type).

```elm
-- BEFORE:
wrapClosureToCanonical originalInfo originalBody originalType canonicalSeg ctx0 =
    let
        ( flatArgs, flatRet ) =
            Mono.decomposeFunctionType originalType

        targetType =
            buildSegmentedFunctionType canonicalSeg flatArgs flatRet

        region =
            Closure.extractRegion (Mono.MonoClosure originalInfo originalBody originalType)
    in
    buildNestedWrapper
        targetType
        (Mono.MonoClosure originalInfo originalBody originalType)  -- Uses originalType
        []
        ctx0

-- AFTER:
wrapClosureToCanonical originalInfo originalBody originalType canonType canonicalSeg ctx0 =
    let
        -- Use originalType for segmentation derivation (flat args/ret)
        ( flatArgs, flatRet ) =
            Mono.decomposeFunctionType originalType

        targetType =
            buildSegmentedFunctionType canonicalSeg flatArgs flatRet

        region =
            Closure.extractRegion (Mono.MonoClosure originalInfo originalBody canonType)
    in
    buildNestedWrapper
        targetType
        (Mono.MonoClosure originalInfo originalBody canonType)  -- Uses canonType for GOPT_001
        []
        ctx0
```

### Step 6: Rewriter.elm - Canonicalize Tail Function Types (All Branches)

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm`
**Function:** `rewriteNode` (lines 93-168, `MonoTailFunc` branch)

**Change:** Compute `canonType` and use it in all cases. (Tail functions don't have wrapper helpers like closures, so the existing wrapper path already uses `flattenTypeToArity`.)

```elm
-- BEFORE:
Mono.MonoTailFunc params body monoType ->
    let
        pid = ProducerTailFunc nodeId
        key = producerIdToKey pid
        maybeClassId = Dict.get identity key solution.producerClass
    in
    case maybeClassId of
        Nothing ->
            let ( newBody, ctx1 ) = rewriteExpr solution producerInfo body ctx0
            in ( Mono.MonoTailFunc params newBody monoType, ctx1 )

        Just classId ->
            let
                canonicalSeg = Dict.get identity classId solution.classSeg |> Maybe.withDefault []
                naturalSeg = Dict.get identity key producerInfo.naturalSeg |> Maybe.withDefault []
                ( newBody, ctx1 ) = rewriteExpr solution producerInfo body ctx0
            in
            if naturalSeg == canonicalSeg then
                ( Mono.MonoTailFunc params newBody monoType, ctx1 )
            else
                let
                    totalArity = Dict.get identity key producerInfo.totalArity |> Maybe.withDefault (List.length params)
                    newType = flattenTypeToArity totalArity monoType
                in
                ( Mono.MonoTailFunc params newBody newType, ctx1 )

-- AFTER:
Mono.MonoTailFunc params body monoType ->
    let
        pid = ProducerTailFunc nodeId
        key = producerIdToKey pid
        maybeClassId = Dict.get identity key solution.producerClass
        ( newBody, ctx1 ) = rewriteExpr solution producerInfo body ctx0

        -- GOPT_001: Always compute canonical type
        paramCount = List.length params
        canonType = flattenTypeToArity paramCount monoType
    in
    case maybeClassId of
        Nothing ->
            -- No staging class: enforce GOPT_001
            ( Mono.MonoTailFunc params newBody canonType, ctx1 )

        Just classId ->
            let
                canonicalSeg = Dict.get identity classId solution.classSeg |> Maybe.withDefault []
                naturalSeg = Dict.get identity key producerInfo.naturalSeg |> Maybe.withDefault []
            in
            if naturalSeg == canonicalSeg then
                -- No wrapper needed: enforce GOPT_001
                ( Mono.MonoTailFunc params newBody canonType, ctx1 )
            else
                -- Wrapper/adaptation needed: canonType already satisfies GOPT_001
                ( Mono.MonoTailFunc params newBody canonType, ctx1 )
```

**Note:** The tail function wrapper path now simplifies since `canonType` already handles the type flattening. The old `totalArity` lookup is no longer needed because `paramCount` is the correct arity for GOPT_001.

---

## Verification Plan

### Step 7: Run Existing Tests

```bash
# Frontend tests
cd compiler && npx elm-test-rs --fuzz 1

# Backend E2E tests
cmake --build build --target full
```

### Step 8: Verify GOPT_001 Invariant

The existing GOPT_001 invariant tests should now pass for all cases:
- Lambdas (`MonoClosure`) - standalone and in staging classes
- Tail functions (`MonoTailFunc`) - top-level and let-bound
- Functions that don't participate in any staging class
- Inner closures within wrappers

### Step 9: Verify Related Invariants

Run tests for:
- CGEN_052 (remaining_arity consistency)
- REP_ABI_001 (ABI representation)
- MONO_004 (function-typed defines)

### Step 10: Add Explicit Tail Function Test

Add a test case that mirrors the "Two-argument lambda" closure test but as a tail function:

```elm
-- Test case: Two-argument tail function (GOPT_001)
foo : Int -> Int -> Int
foo x y = x
```

After GlobalOpt:
- `foo`'s `MonoTailFunc` type must be flattened to match `params`
- Type: `MFunction [Int, Int] Int` (not `MFunction [Int] (MFunction [Int] Int)`)
- No GOPT_001 failure reported

---

## Resolved Questions

### Q1: Wrapper behavior when `naturalSeg != canonicalSeg` ✓ RESOLVED

**Answer:** The inner closure/tail function **must** also have `canonType`. The wrapper exists only to adapt segmentation/staging ABI, not to exempt the inner node from GOPT_001. The inner node is still a real node in the mono graph with its own `params` and `type`, so leaving it in curried form would:
- Violate GOPT_001 for the inner node
- Cause passes/checks that inspect the inner node to see the mismatch

**Implementation:** Pass `canonType` to `wrapClosureToCanonical` and use it for the inner closure's type.

### Q2: flattenTypeToArity edge case ✓ RESOLVED

**Answer:** When `allArgs.length < paramCount`, this is a hard inconsistency that should never happen in a well-formed mono graph. The current behavior (return unchanged) masks bugs.

**Implementation:** Change to `Debug.todo` with descriptive error message. This ensures:
- On correct programs, it never fires
- If it does fire, you get a precise "mono graph inconsistent" error

### Q3: Import of `ProducerTailFunc` in GraphBuilder ✓ RESOLVED

**Answer:** Yes, `ProducerId(..)` is imported in GraphBuilder, which exposes all constructors including `ProducerTailFunc`.

### Q4: nodeId availability in foldNode ✓ RESOLVED

**Answer:** Yes, confirmed by reading ProducerInfo.elm line 47: `ProducerTailFunc nodeId` uses the same node ID that's passed to `foldNode`.

### Q5: Test coverage for standalone closures ✓ RESOLVED

**Answer:** The "Two-argument lambda" test (`\x y -> x`) is the concrete failing case:
- No captures
- Not a branch result
- Not in an aggregate
- Not passed as a function argument

This closure never became a producer node, never got a class, never had its type flattened → violated GOPT_001.

---

## Risk Assessment

### Low Risk
- GraphBuilder changes are additive (just ensure producer nodes exist)
- `flattenTypeToArity` error case only fires on broken input (defensive)

### Medium Risk
- If some downstream code depends on the nested function type structure (e.g., `MFunction [Int] (MFunction [Int] Int)` vs `MFunction [Int, Int] Int`), canonicalization could break it
- Wrapper function signature change requires updating call sites

### Mitigation
- Run full test suite after each step
- The wrapper logic (segmentation derivation) is unchanged; only the inner closure's type annotation changes
- After GraphBuilder fix, formerly "standalone" closures/tail funcs will normally get a class, so the `Nothing` branch becomes a safety net
