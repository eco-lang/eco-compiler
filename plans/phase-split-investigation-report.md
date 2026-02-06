# Investigation Report: Monomorphize vs GlobalOpt Phase Split

## Executive Summary

The current split of staging logic between Monomorphize and GlobalOpt phases is **not clean**. There is staging/uncurrying logic in three places:

1. **Monomorphize/Specialize.elm** – Makes initial staging decisions for closures
2. **GlobalOpt/MonoGlobalOptimize.elm** – Normalizes ABI and validates staging
3. **Generate/MLIR/Types.elm** – Duplicates staging utilities for codegen

This creates a **tangled dependency** where:
- Monomorphize must understand staging to create closures
- GlobalOpt must re-normalize staging for ABI consistency
- MLIR codegen has its own copy of staging utilities

## Detailed Analysis

### 1. Staging Logic in Monomorphize Phase

#### `specializeLambda` (Specialize.elm:136-407)

This function makes **critical staging decisions** during type specialization:

```elm
-- Key decision point (lines 249-270):
isFullyPeelable : Bool
isFullyPeelable =
    paramCount == totalArity

effectiveMonoType : Mono.MonoType
effectiveMonoType =
    if isFullyPeelable then
        Mono.MFunction flatArgTypes flatRetType
    else
        -- Wrapper: build MFunction with first paramCount args
        let
            wrapperArgs = List.take paramCount flatArgTypes
            wrapperReturnType = dropNArgsFromType paramCount monoType0
        in
        Mono.MFunction wrapperArgs wrapperReturnType
```

**Evidence of staging logic:**
- `isFullyPeelable` determines whether to flatten or stage the function type
- `dropNArgsFromType` (lines 93-112) manipulates nested `MFunction` chains
- MONO_016 assertion embedded in closure creation (lines 301-313)

#### `ensureCallableTopLevel` (Closure.elm:52-119)

This function creates **stage-aware closure wrappers**:

```elm
-- Uses staging helpers (lines 57-63):
stageArgTypes = Mono.stageParamTypes monoType
stageRetType = Mono.stageReturnType monoType
stageArity = List.length stageArgTypes
```

**Evidence of staging logic:**
- Directly uses `Mono.stageParamTypes`, `Mono.stageReturnType`
- Creates closures with exactly `stageArity` parameters
- Has MONO_016-aware crash message (lines 76-83)

### 2. Staging Logic in GlobalOpt Phase

#### `globalOptimize` (MonoGlobalOptimize.elm:57-75)

GlobalOpt has **4 phases**, with staging logic in phases 1-3:

```elm
globalOptimize typeEnv graph0 =
    let
        -- Phase 1: ABI normalization (case/if result types, wrapper generation)
        graph1 = normalizeCaseIfAbi graph0

        -- Phase 2: Closure staging invariant check
        graph2 = validateClosureStaging graph1

        -- Phase 3: Returned-closure arity annotation
        graph3 = annotateReturnedClosureArity graph2
    in
    graph3
```

#### `rewriteCaseForAbi` (MonoGlobalOptimize.elm:577-606)

Normalizes case expression branches to have consistent staging:

```elm
-- Lines 595-603:
( canonicalSeg, flatArgs, flatRet ) =
    Mono.chooseCanonicalSegmentation leafTypes

canonicalType =
    Mono.buildSegmentedFunctionType flatArgs flatRet canonicalSeg
```

#### `buildAbiWrapperGO` (MonoGlobalOptimize.elm:317-378)

Creates wrapper closures to adapt one staging to another:

```elm
-- Lines 323-327:
targetSeg = Mono.segmentLengths targetType
srcSeg = Mono.segmentLengths srcType

if targetSeg == srcSeg then
    ( calleeExpr, ctx0 )
else
    -- Build nested closure stages...
```

#### `validateExprClosures` (MonoGlobalOptimize.elm:986-1073)

Enforces MONO_016 invariant after ABI normalization:

```elm
-- Lines 988-1005:
Mono.MonoClosure info body tipe ->
    let
        expectedParams = Mono.stageParamTypes tipe
        actualParams = info.params
        _ =
            if List.length actualParams /= List.length expectedParams then
                Debug.todo ("MONO_016 violation: closure has "
                    ++ String.fromInt (List.length actualParams)
                    ++ " params but type expects "
                    ++ String.fromInt (List.length expectedParams))
            else ()
    in
    validateExprClosures body
```

### 3. Duplicate Staging Logic in MLIR/Types.elm

The MLIR codegen module has **complete duplicates** of staging utilities:

```elm
-- MLIR/Types.elm exports (line 9):
Segmentation, buildSegmentedFunctionType, chooseCanonicalSegmentation,
segmentLengths, stageArity, stageParamTypes, stageReturnType
```

These are used in:
- `MLIR/Functions.elm:238-241` – `Types.stageReturnType`
- `MLIR/Expr.elm:991-1122` – `Types.stageArity`, `Types.stageReturnType`

**Example duplicate (MLIR/Types.elm:289-295):**
```elm
stageParamTypes monoType =
    case monoType of
        Mono.MFunction argTypes _ ->
            argTypes
        _ ->
            []
```

This is identical to `Mono.stageParamTypes` in `Monomorphized.elm`.

## Findings

### Finding 1: Monomorphize Makes Staging Decisions

**Location:** `Specialize.elm:249-270`

**Evidence:**
- `isFullyPeelable` check determines whether to flatten or stage
- `effectiveMonoType` is built with staging awareness
- `dropNArgsFromType` manipulates nested `MFunction` chains

**Assessment:** This is **type specialization mixed with code shaping**. The decision of how to stage a closure is a code shaping concern, not a type specialization concern.

### Finding 2: GlobalOpt Must Re-Normalize Staging

**Location:** `MonoGlobalOptimize.elm:577-606`

**Evidence:**
- `chooseCanonicalSegmentation` picks a common staging for case branches
- `buildAbiWrapperGO` creates adapter closures
- This work happens **after** Monomorphize already made staging decisions

**Assessment:** GlobalOpt has to fix up the staging that Monomorphize created. This suggests Monomorphize is doing work that GlobalOpt should own.

### Finding 3: MONO_016 Is Checked Twice

**Locations:**
1. `Specialize.elm:301-313` – During closure creation in Monomorphize
2. `MonoGlobalOptimize.elm:986-1005` – After ABI normalization in GlobalOpt

**Evidence:**
- Both locations have similar MONO_016 violation crash messages
- The Monomorphize check happens before GlobalOpt's ABI normalization
- The GlobalOpt check happens after ABI normalization

**Assessment:** If Monomorphize didn't make staging decisions, the first check wouldn't be needed. Only GlobalOpt should enforce MONO_016 after it owns all staging logic.

### Finding 4: Code Duplication in MLIR/Types.elm

**Location:** `MLIR/Types.elm:289-431`

**Evidence:**
- `stageParamTypes`, `stageReturnType`, `stageArity` are exact duplicates
- `segmentLengths`, `buildSegmentedFunctionType`, `chooseCanonicalSegmentation` are duplicates
- These should be imported from `Mono.*` instead

**Assessment:** This is technical debt. MLIR codegen should use `Mono.*` functions, not maintain its own copies.

### Finding 5: `ensureCallableTopLevel` Uses Staging

**Location:** `Closure.elm:52-119`

**Evidence:**
- Uses `Mono.stageParamTypes`, `Mono.stageReturnType`
- Creates closures with exactly stage-arity parameters
- Called during Monomorphize phase

**Assessment:** This function is stage-aware by design. It needs staging information to create correct closures. However, the **decision** of what the staging should be could be deferred to GlobalOpt.

## Phase Split Assessment

### Current State

| Concern | Monomorphize | GlobalOpt | MLIR |
|---------|-------------|-----------|------|
| Type specialization | ✓ | | |
| Closure creation | ✓ | ✓ (wrappers) | |
| Staging decisions | ✓ (isFullyPeelable) | ✓ (canonical) | |
| ABI normalization | | ✓ | |
| MONO_016 check | ✓ | ✓ | |
| Staging utilities | Uses Mono.* | Uses Mono.* | Duplicates |

### Ideal State

| Concern | Monomorphize | GlobalOpt | MLIR |
|---------|-------------|-----------|------|
| Type specialization | ✓ | | |
| Closure creation | ✓ (unstaged) | ✓ (staged) | |
| Staging decisions | | ✓ | |
| ABI normalization | | ✓ | |
| MONO_016 check | | ✓ | |
| Staging utilities | | ✓ | Uses Mono.* |

## Specific Code That May Need to Move

### 1. `isFullyPeelable` Logic (Specialize.elm:249-270)

**Current:** Makes staging decision during type specialization.

**Proposed:** Monomorphize always creates "unstaged" closures with all params flattened. GlobalOpt then applies staging during ABI normalization.

**Complexity:** High. This affects the entire flow of how `effectiveMonoType` is computed.

### 2. `dropNArgsFromType` (Specialize.elm:93-112)

**Current:** Used by `specializeLambda` for wrapper type calculation.

**Proposed:** If Monomorphize doesn't make staging decisions, this function may not be needed there. Move to GlobalOpt or `Mono.*`.

**Complexity:** Medium. This is a utility function.

### 3. MONO_016 Assertion in `specializeLambda` (Specialize.elm:301-313)

**Current:** Checks staging invariant during closure creation.

**Proposed:** Remove. Let GlobalOpt be the sole enforcer after it applies staging.

**Complexity:** Low, but requires confidence that GlobalOpt's validation is sufficient.

### 4. Staging Utilities in MLIR/Types.elm (Types.elm:289-431)

**Current:** Duplicate implementations of staging utilities.

**Proposed:** Delete and import from `Mono.*`.

**Complexity:** Low. Simple replacement.

## Questions and Open Issues

1. **Can Monomorphize create "unstaged" closures?**
   - If closures always have all params flattened, how does this affect the intermediate representation?
   - Would GlobalOpt need to restructure closures, or just annotate their staging?

2. **What about `ensureCallableTopLevel`?**
   - This function creates stage-aware closures by design.
   - If we defer staging to GlobalOpt, do we need to change how it creates wrappers?

3. **Performance implications?**
   - If GlobalOpt must re-process all closures to apply staging, is there a performance cost?
   - Currently Monomorphize does some of this work.

4. **Test coverage for staging?**
   - The 2 failing tests mention MONO_018 violations (different invariant).
   - Need to verify there are adequate tests for MONO_016 and staging behavior.

## Recommendations

1. **Delete MLIR/Types.elm duplicates** – Low risk, clear win.

2. **Consolidate MONO_016 checking to GlobalOpt** – Remove the assertion in `specializeLambda`, rely on `validateClosureStaging`.

3. **Consider refactoring `specializeLambda`** – The `isFullyPeelable` / `effectiveMonoType` logic is the core staging decision. Moving this to GlobalOpt would be the cleanest separation but has highest complexity.

4. **Document the current split** – If refactoring is too risky, at least document why staging logic is in two places.

## Conclusion

The current split has staging logic in Monomorphize that should ideally be in GlobalOpt. The key evidence is:

1. `specializeLambda`'s `isFullyPeelable` decision is a code shaping concern
2. GlobalOpt must re-normalize staging anyway (case/if branches)
3. MONO_016 is checked twice
4. MLIR codegen has duplicate staging utilities

A clean split would have:
- **Monomorphize:** Pure type specialization, creates closures without staging decisions
- **GlobalOpt:** Applies staging, normalizes ABI, validates MONO_016
- **MLIR:** Uses `Mono.*` utilities, no duplicates

However, achieving this requires careful refactoring of `specializeLambda` and `ensureCallableTopLevel`, which is non-trivial.
