# Plan: Consolidate Staging Logic into GlobalOpt

## Overview

This plan consolidates **all staging logic and calling-convention decisions into GlobalOpt**. Currently, staging-aware wrapper creation is split between Monomorphize and GlobalOpt, and MLIR codegen directly uses staging helpers (`Mono.stageArity`, `Mono.stageReturnType`, `Mono.segmentLengths`). After this refactor:

- **Monomorphize**: Produces curried, staging-agnostic types reflecting Elm semantics. No ABI/calling-convention decisions. No staging-driven closures (except user-written lambdas via `specializeLambda`).
- **GlobalOpt**: Owns all staging decisions, wrapper insertion, and calling-convention normalization.
- **MLIR codegen**: Consumes canonical types from GlobalOpt without calling staging helpers directly.

## Target Invariants

1. Monomorphize output has no staging-driven wrappers (user lambdas are allowed)
2. GlobalOpt is the single source of truth for staging/ABI decisions
3. MLIR codegen uses precomputed staging metadata from GlobalOpt signatures

---

## Phase 1: Add Staging Logic to GlobalOpt

**Goal:** Add the new GlobalOpt helpers while keeping Monomorphize's `ensureCallableTopLevel` in place. This allows incremental testing.

### Step 1.1: Add `buildNestedCallsGO` helper

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

**Add new function** (near `buildAbiWrapperGO`):

```elm
{-| Build nested calls that apply all params to a callee, respecting the callee's staging.
Given calleeType with segmentation [2,3] and params [a,b,c,d,e]:
  - First call: callee(a,b) -> intermediate1
  - Second call: intermediate1(c,d,e) -> result
This follows MONO_016: never pass more args to a stage than it accepts.
-}
buildNestedCallsGO : A.Region -> Mono.MonoExpr -> List ( Name, Mono.MonoType ) -> Mono.MonoExpr
buildNestedCallsGO region calleeExpr params =
    let
        calleeType =
            Mono.typeOf calleeExpr

        srcSeg =
            Mono.segmentLengths calleeType

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        buildCalls : Mono.MonoExpr -> List Mono.MonoExpr -> List Int -> Mono.MonoExpr
        buildCalls currentCallee remainingArgs segLengths =
            case ( segLengths, remainingArgs ) of
                ( [], _ ) ->
                    currentCallee

                ( m :: restSeg, _ ) ->
                    let
                        ( nowArgs, laterArgs ) =
                            ( List.take m remainingArgs, List.drop m remainingArgs )

                        currentCalleeType =
                            Mono.typeOf currentCallee

                        resultType =
                            Mono.stageReturnType currentCalleeType

                        callExpr =
                            Mono.MonoCall region currentCallee nowArgs resultType
                    in
                    buildCalls callExpr laterArgs restSeg
    in
    buildCalls calleeExpr paramExprs srcSeg
```

### Step 1.2: Add closure wrapper builders using `GlobalCtx`

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

**Add new functions:**

```elm
makeAliasClosureGO :
    IO.Canonical
    -> Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
makeAliasClosureGO home calleeExpr argTypes retType funcType ctx =
    let
        params =
            Closure.freshParams argTypes

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        ( lambdaId, ctx1 ) =
            freshLambdaId home ctx

        region =
            Closure.extractRegion calleeExpr

        callExpr =
            Mono.MonoCall region calleeExpr paramExprs retType

        captures =
            Closure.computeClosureCaptures params callExpr

        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = params
            }
    in
    ( Mono.MonoClosure closureInfo callExpr funcType, ctx1 )


makeGeneralClosureGO :
    IO.Canonical
    -> Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
makeGeneralClosureGO home expr argTypes retType funcType ctx =
    let
        params =
            Closure.freshParams argTypes

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        ( lambdaId, ctx1 ) =
            freshLambdaId home ctx

        region =
            Closure.extractRegion expr

        callExpr =
            Mono.MonoCall region expr paramExprs retType

        captures =
            Closure.computeClosureCaptures params callExpr

        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = params
            }
    in
    ( Mono.MonoClosure closureInfo callExpr funcType, ctx1 )
```

### Step 1.3: Add `ensureCallableForNode` function

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

**Add new function:**

```elm
{-| Ensure a top-level node expression is directly callable.
This wraps bare MonoVarGlobal/MonoVarKernel in closures.
Called during ABI normalization, BEFORE rewriteExprForAbi.
-}
ensureCallableForNode :
    IO.Canonical
    -> Mono.MonoExpr
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
ensureCallableForNode home expr monoType ctx =
    case monoType of
        Mono.MFunction _ _ ->
            let
                stageArgTypes =
                    Mono.stageParamTypes monoType

                stageRetType =
                    Mono.stageReturnType monoType
            in
            case expr of
                Mono.MonoClosure _ _ _ ->
                    -- Already a closure: nothing to do
                    ( expr, ctx )

                Mono.MonoVarGlobal region specId _ ->
                    -- Alias wrapper around a global function specialization
                    makeAliasClosureGO home
                        (Mono.MonoVarGlobal region specId monoType)
                        stageArgTypes
                        stageRetType
                        monoType
                        ctx

                Mono.MonoVarKernel region kernelHome name kernelAbiType ->
                    -- Kernels use flattened ABI (all params at once)
                    let
                        ( kernelFlatArgTypes, kernelFlatRetType ) =
                            Closure.flattenFunctionType kernelAbiType

                        flattenedFuncType =
                            Mono.MFunction kernelFlatArgTypes kernelFlatRetType
                    in
                    makeAliasClosureGO home
                        (Mono.MonoVarKernel region kernelHome name kernelAbiType)
                        kernelFlatArgTypes
                        kernelFlatRetType
                        flattenedFuncType
                        ctx

                _ ->
                    -- General expression: wrap in a closure using staging of monoType
                    makeGeneralClosureGO home expr stageArgTypes stageRetType monoType ctx

        _ ->
            -- Non-function: leave as-is
            ( expr, ctx )
```

### Step 1.4: Integrate into `rewriteNodeForAbi`

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

**Modify `rewriteNodeForAbi` (lines 1191-1244):**

For `Mono.MonoDefine`, `Mono.MonoPortIncoming`, `Mono.MonoPortOutgoing`:

```elm
-- BEFORE:
Mono.MonoDefine expr tipe ->
    let
        ( newExpr, ctx1 ) = rewriteExprForAbi home expr ctx
    in
    ( Mono.MonoDefine newExpr tipe, ctx1 )

-- AFTER:
Mono.MonoDefine expr tipe ->
    let
        ( callableExpr, ctx0 ) = ensureCallableForNode home expr tipe ctx
        ( newExpr, ctx1 ) = rewriteExprForAbi home callableExpr ctx0
    in
    ( Mono.MonoDefine newExpr tipe, ctx1 )
```

Same pattern for `Mono.MonoPortIncoming` and `Mono.MonoPortOutgoing`.

### Step 1.5: Update `buildAbiWrapperGO` to use local helper

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

**Modify `buildAbiWrapperGO` (line 649):**

```elm
-- BEFORE:
( Closure.buildNestedCalls region calleeExpr accParams, ctx )

-- AFTER:
( buildNestedCallsGO region calleeExpr accParams, ctx )
```

### Step 1.6: Run tests to verify GlobalOpt additions

```bash
cd compiler && npx elm-test-rs --fuzz 1
cmake --build build --target check
```

At this point, both Monomorphize AND GlobalOpt wrap expressions. This is temporarily redundant but safe—GlobalOpt's `ensureCallableForNode` will see already-wrapped closures and return them unchanged.

---

## Phase 2: Remove Staging Wrappers from Monomorphize

**Goal:** Once GlobalOpt wrappers are proven correct, remove all calls to `Closure.ensureCallableTopLevel` from Monomorphize.

### Step 2.1: Remove `ensureCallableTopLevel` calls from `Specialize.elm`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

**Changes:**

1. **`specializeNode` function (lines 180-298)**
   - Remove `ensureCallableTopLevel` call for `TOpt.Define` case (lines 188-200)
   - Remove `ensureCallableTopLevel` call for `TOpt.TrackedDefine` case (lines 202-216)
   - Remove `ensureCallableTopLevel` call for `TOpt.PortIncoming` case (lines 272-283)
   - Remove `ensureCallableTopLevel` call for `TOpt.PortOutgoing` case (lines 285-296)

2. **`specializeFuncDefInCycle` function (lines 455-514)**
   - Remove `ensureCallableTopLevel` call for `TOpt.Def` case (lines 461-477)

**Pattern for each removal:**
```elm
-- BEFORE:
( monoExpr0, state1 ) = specializeExpr expr subst state
( monoExpr, state2 ) = Closure.ensureCallableTopLevel monoExpr0 monoType state1
actualType = Mono.typeOf monoExpr

-- AFTER:
( monoExpr, state1 ) = specializeExpr expr subst state
actualType = Mono.typeOf monoExpr
```

### Step 2.2: Remove `checkCallableTopLevels` from `Monomorphize.elm`

**File:** `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

**Changes:**

1. In `monomorphizeFromEntry` (lines 152-211), remove the `case checkCallableTopLevels finalState of` block and directly return `Ok (Mono.MonoGraph {...})`.

2. Keep `checkCallableTopLevels` function definition (can be used for debugging) but it's no longer in the production path.

### Step 2.3: Reduce exports from `Closure.elm`

**File:** `compiler/src/Compiler/Monomorphize/Closure.elm`

**Changes:**

1. Update module exposing list (lines 1-6):
```elm
-- BEFORE:
module Compiler.Monomorphize.Closure exposing
    ( ensureCallableTopLevel
    , freshParams, extractRegion, buildNestedCalls
    , computeClosureCaptures
    , flattenFunctionType
    )

-- AFTER:
module Compiler.Monomorphize.Closure exposing
    ( freshParams, extractRegion
    , computeClosureCaptures
    , flattenFunctionType
    )
```

2. Delete staging-aware functions (keep staging-neutral utilities):
   - DELETE: `ensureCallableTopLevel` (lines 53-105)
   - DELETE: `makeAliasClosure` (lines 134-166)
   - DELETE: `makeGeneralClosure` (lines 178-213)
   - DELETE: `buildNestedCalls` (lines 230-266)
   - KEEP: `flattenFunctionType`, `freshParams`, `extractRegion`, `computeClosureCaptures`

### Step 2.4: Run tests to verify Monomorphize cleanup

```bash
cd compiler && npx elm-test-rs --fuzz 1
cmake --build build --target check
```

---

## Phase 3: Remove Staging Helper Usage from MLIR Codegen

**Goal:** Remove all `Mono.stageArity`, `Mono.stageReturnType`, `Mono.segmentLengths` usage from MLIR. Use precomputed metadata from GlobalOpt signatures instead.

### Step 3.1: Refactor call modeling in `Expr.elm`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Modify call arity computation (lines 977-1003):**

Replace direct `Mono.stageArity` calls with signature-based lookups:

```elm
( firstStageArity, totalArity ) =
    case func of
        Mono.MonoVarGlobal _ specId _ ->
            case Dict.get specId ctx.signatures of
                Just sig ->
                    let
                        firstStage =
                            List.length sig.paramTypes

                        extraFromReturned =
                            case sig.returnedClosureParamCount of
                                Just n -> n
                                Nothing -> 0
                    in
                    ( firstStage, firstStage + extraFromReturned )

                Nothing ->
                    -- Fallback: treat MonoType as flat
                    let
                        t = Mono.typeOf func
                    in
                    ( Types.countTotalArity t, Types.countTotalArity t )

        Mono.MonoClosure closureInfo _ _ ->
            let
                firstStage = List.length closureInfo.params
            in
            ( firstStage, firstStage )

        _ ->
            let
                t = Mono.typeOf func
                total = Types.countTotalArity t
            in
            ( total, total )
```

### Step 3.2: Refactor `applyByStages` to be metadata-driven

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Modify signature (lines 1045-1142):**

1. Remove `funcMonoType` parameter from signature:
```elm
-- BEFORE:
applyByStages ctx funcVar funcMlirType funcMonoType sourceRemaining returnedClosureParamCount args accOps =

-- AFTER:
applyByStages ctx funcVar funcMlirType sourceRemaining returnedClosureParamCount args accOps =
```

2. Remove lines 1055-1061 that extract `stageN` and `stageRetType` from `funcMonoType`

3. Replace with purely numeric staging based on `sourceRemaining`:
```elm
let
    batchSize =
        min sourceRemaining (List.length args)

    ( batch, rest ) =
        ( List.take batchSize args, List.drop batchSize args )

    rawResultRemaining =
        sourceRemaining - batchSize

    resultRemaining =
        if rawResultRemaining <= 0 then
            case returnedClosureParamCount of
                Just paramCount -> paramCount
                Nothing -> 0
        else
            rawResultRemaining
```

4. Remove line 1122 fallback to `Mono.stageArity stageRetType`

**Note on result types:** After each `eco.papExtend`, the result type is always `!eco.value` (per CGEN_034). Any immediate result is produced via subsequent `eco.unbox` where needed. So `resultMlirType` remains `!eco.value` throughout PAP chains.

### Step 3.3: Update call site of `applyByStages`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**In `generateClosureApplication`:** Remove the `funcType` argument when calling `applyByStages`.

### Step 3.4: Refactor staging usage in `Functions.elm`

**File:** `compiler/src/Compiler/Generate/MLIR/Functions.elm`

**Modify line 241:**

```elm
-- BEFORE:
extractedReturnType = Mono.stageReturnType monoType

-- AFTER:
-- Derive return type from canonical monoType after GlobalOpt
-- For closures, the return type is the type stripped of first-stage params
extractedReturnType =
    case monoType of
        Mono.MFunction _ retType -> retType
        _ -> monoType
```

**Note:** This works because after GlobalOpt, the `monoType` is already canonical and `MFunction params ret` has `ret` as the stage return type.

### Step 3.5: Run tests with CGEN invariant focus

```bash
cmake --build build --target check
# Pay special attention to CGEN_052 and CGEN_055 related tests
```

---

## Phase 4: Invariant and Test Updates

### Step 4.1: Update `invariants.csv`

**File:** `design_docs/invariants.csv`

1. **Update MONO_004** to specify "enforced after GlobalOpt" not "after Monomorphize"

2. **Add new FORBID invariant:**
   ```
   FORBID_STAGING_001,No phase other than GlobalOpt may use stageParamTypes/stageReturnType/segmentLengths for ABI/wrapper decisions,CODE_REVIEW,NONE
   ```

3. **Clarify GOPT_016-018** as the authoritative staging enforcement points

### Step 4.2: Final verification

```bash
cd compiler && npx elm-test-rs --fuzz 1
cmake --build build --target check
```

---

## Execution Summary

| Step | Description | Test After |
|------|-------------|------------|
| 1.1-1.5 | Add GlobalOpt helpers | Yes |
| 1.6 | Verify redundant wrapping is safe | Yes |
| 2.1-2.3 | Remove Monomorphize wrappers | Yes |
| 2.4 | Verify GlobalOpt-only wrapping | Yes |
| 3.1-3.4 | Remove MLIR staging helpers | Yes |
| 3.5 | Verify CGEN invariants | Yes |
| 4.1-4.2 | Update docs, final verification | Yes |

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking kernel wrapper handling | Preserve `flattenFunctionType` logic in `ensureCallableForNode` for kernels |
| Missing staging info in MLIR | Ensure GlobalOpt signatures include `returnedClosureParamCount` |
| Cycle specialization edge cases | Test with complex recursive function groups |
| Order of operations in GlobalOpt | Call `ensureCallableForNode` BEFORE `rewriteExprForAbi` |
| Double-wrapping during transition | Phase 1 adds wrappers while Monomorphize still wraps; `ensureCallableForNode` handles already-wrapped closures as no-op |

---

## Success Criteria

1. All existing tests pass
2. No calls to `Mono.stageArity`, `Mono.stageReturnType`, `Mono.segmentLengths` in MLIR directory
3. `Closure.elm` exports only staging-neutral utilities: `freshParams`, `extractRegion`, `computeClosureCaptures`, `flattenFunctionType`
4. `checkCallableTopLevels` no longer in production path
5. No `ensureCallableTopLevel` calls in Monomorphize

---

## Resolved Questions

### Q1: Lambda counter coordination
**Resolution:** Safe. `initGlobalCtx` scans the completed `MonoGraph` via `maxLambdaIndexInGraph` and sets `lambdaCounter` to "max + 1". Because GlobalOpt runs strictly after Monomorphize, and no later phase creates new Mono lambdas, there's no conflict. No shared state needed.

### Q2: Interaction between `ensureCallableForNode` and `buildAbiWrapperGO`
**Resolution:** No conflict. They serve different purposes at different structural points:
- `ensureCallableForNode`: Wraps top-level node bodies (defs/ports) that are bare VarGlobal/VarKernel
- `buildAbiWrapperGO`: Normalizes staging at case/if joins where branch segmentations differ

Execution order in `globalOptimize`:
1. `canonicalizeClosureStaging`
2. `normalizeCaseIfAbi` (calls `rewriteNodeForAbi`, which calls `ensureCallableForNode` then `rewriteExprForAbi`)
3. `validateClosureStaging`
4. `annotateReturnedClosureArity`

### Q3: User-written lambdas in `specializeLambda`
**Resolution:** Keep `specializeLambda` producing `MonoClosure` for user lambdas in Monomorphize. This is fundamentally different from synthetic wrappers. Monomorphize still handles closures and captures; it just stops making staging decisions for top-level wrappers.

### Q4: `TrackedDefine` handling
**Resolution:** Apply same changes as `TOpt.Def`. Based on code review, it follows the same pattern.

### Q5: MLIR `resultMlirType` computation
**Resolution:** After each `eco.papExtend`, result type is always `!eco.value` (per CGEN_034). Responsibility for unboxing/coercion stays with callers (which already coerce to `expectedType` in call lowering). Use `funcMlirType` (which is `!eco.value`) as result type throughout PAP chains.

---

## Files Modified Summary

| File | Changes |
|------|---------|
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | Add `buildNestedCallsGO`, `makeAliasClosureGO`, `makeGeneralClosureGO`, `ensureCallableForNode`; modify `rewriteNodeForAbi`, `buildAbiWrapperGO` |
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Remove 5 `ensureCallableTopLevel` calls |
| `compiler/src/Compiler/Monomorphize/Monomorphize.elm` | Remove `checkCallableTopLevels` from production path |
| `compiler/src/Compiler/Monomorphize/Closure.elm` | Delete 4 functions (`ensureCallableTopLevel`, `makeAliasClosure`, `makeGeneralClosure`, `buildNestedCalls`), reduce exports |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Refactor call modeling (remove `Mono.stageArity` usage), refactor `applyByStages` to be metadata-driven |
| `compiler/src/Compiler/Generate/MLIR/Functions.elm` | Replace `Mono.stageReturnType` with direct `MFunction` pattern match |
| `design_docs/invariants.csv` | Update MONO_004, add FORBID_STAGING_001 |
