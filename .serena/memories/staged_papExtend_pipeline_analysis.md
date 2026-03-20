# Staged papExtend Chain Generation Pipeline

## Overview

The Eco compiler generates staged `eco.papExtend` calls for combinator-style function calls like:
```elm
k a _ = a
s bf uf x = bf x (uf x)
b = s (k s) k
result = b square inc 4
```

This document traces the full pipeline from Elm call site to MLIR papExtend generation, identifying the bug location.

## Test File Location

- **File**: `/work/test/elm/src/CombinatorBComposeTest.elm`
- **Expected result**: `b square inc 4 = 25` (composition of square and inc on 4)

## Key Data Structure: CallInfo

Located in `/work/compiler/src/Compiler/AST/Monomorphized.elm` (line 1087):

```elm
type alias CallInfo =
    { callModel : CallModel                    -- FlattenedExternal or StageCurried
    , stageArities : List Int                 -- Full stage arities [a1, a2, ...]
    , isSingleStageSaturated : Bool           -- True if call consumes all args in first stage
    , initialRemaining : Int                  -- CRUCIAL: stage arity at THIS call site
    , remainingStageArities : List Int        -- Arities for subsequent stages after saturation
    , closureKind : MaybeClosureKind
    , captureAbi : Maybe CaptureABI
    , callKind : CallKind                     -- CallDirectKnownSegmentation, CallDirectFlat, CallGenericApply
    }

type CallKind
    = CallDirectKnownSegmentation  -- Uses `remaining_arity` in papExtend
    | CallDirectFlat              -- No staging
    | CallGenericApply            -- No `remaining_arity`, runtime-determined
```

## Compiler Pipeline

### Phase: Global Optimization (GlobalOpt)

**File**: `/work/compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

#### Function: `annotateDefCalls` (line ~1830) → `computeCallInfo`

Main entry point that computes CallInfo for each `MonoCall` node.

```elm
computeCallInfo : MonoGraph -> CallEnv -> MonoExpr -> MonoType -> CallInfo
```

#### Step 1: Determine CallModel (line 1834-1836)

```elm
callModel = callModelForCallee graph env func
```

Determines if the callee is:
- `FlattenedExternal`: Kernel/extern (total ABI arity)
- `StageCurried`: User closure (stage-curried)

#### Step 2: Derive Stage Arities from Callee Type (line 1858-1860)

```elm
stageAritiesFull = MonoReturnArity.collectStageArities funcType
```

Analyzes the **static type** of the callee to extract stage segmentation.
For `b : Int -> Int -> ... -> Int`, this extracts how many arguments each stage consumes.

#### Step 3: Determine SOURCE ARITY (line 1862-1878)

**THIS IS WHERE THE BUG OCCURS**

```elm
sourceArityInfo = sourceArityForCallee graph env func
sourceArity = case sourceArityInfo of
    FromProducer a -> a
    FromType _ -> 0
```

The **SOURCE ARITY** is what gets written into the MLIR `remaining_arity` attribute at line 1463 in the papExtend operation.

### Step 4: Source Arity Computation (line 1524-1530)

**Function**: `sourceArityForExpr` (line 1458)

For **`MonoVarLocal name _`** (variables bound by let/case/param):

```elm
Mono.MonoVarLocal name _ ->
    Dict.get name env.varSourceArity
```

This looks up the variable's arity in the `CallEnv.varSourceArity` dictionary.

For **`MonoCall _ func args resultType _`** (partial applications):

```elm
Mono.MonoCall _ func args resultType _ ->
    case sourceArityForExpr graph env func of
        Just sourceArity ->
            let
                argCount = List.length args
                resultArity = sourceArity - argCount
            in
            if resultArity > 0 then
                Just resultArity  -- Partial application
            else
                -- Saturated: use body's stage arities
                case closureBodyStageArities graph func of
                    Just stages -> consumeFromStages excessArgs stages
                    Nothing -> firstStageArityFromType resultType
```

**KEY BUG**: When `b = s (k s) k` is evaluated:
- `s` is a closure with arity 3
- `s (k s) k` partially applies with 2 arguments
- Result arity should be `3 - 2 = 1`

But the problem is:
1. When `b` is used in `b square inc 4`, the compiler looks up `varSourceArity[b]`
2. This value was computed when `b` was defined as the partial application result
3. The arity stored is the **static type's first stage arity**, not the **actual runtime closure arity**

### Step 5: Remaining Stage Arities (line 1896-1913)

```elm
remainingStageArities = case closureBodyStageArities graph func of
    Just arities -> arities
    Nothing -> case func of
        Mono.MonoVarLocal name _ -> Dict.get name env.varBodyStageArities
        _ -> []
```

This looks up what the **closure body returns** in terms of stages.

### Phase: Staging Rewriter (GlobalOpt/Staging)

**File**: `/work/compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm`

The Staging Rewriter wraps closures that don't match canonical staging:

```elm
buildNestedCalls : Region -> MonoExpr -> List (Name, MonoType) -> MonoExpr
```

When building nested calls for staged closures (line 662):

```elm
callInfo = 
    { callModel = Mono.StageCurried
    , stageArities = MonoReturnArity.collectStageArities calleeType
    , isSingleStageSaturated = stageArity == remainingArity && remainingArity > 0
    , initialRemaining = remainingArity  -- <-- Line 658
    , remainingStageArities = restStages  -- <-- Line 659
    , callKind = Mono.CallDirectKnownSegmentation
    }
```

The `initialRemaining` here is `remainingArity` derived from **type decomposition**, not runtime arity.

## MLIR Generation Phase

**File**: `/work/compiler/src/Compiler/Generate/MLIR/Expr.elm`

### Function: `generateClosureApplication` (line 1608)

For `CallDirectKnownSegmentation` calls with `StageCurried` model:

```elm
generateClosureApplication ctx func args resultType callInfo =
    case callInfo.callModel of
        Mono.StageCurried ->
            let
                initialRemaining = callInfo.initialRemaining
                remainingStageArities = callInfo.remainingStageArities
                papResult = applyByStages ctx1b funcResult.resultVar funcResult.resultType 
                            initialRemaining remainingStageArities expectedType 
                            (Just (callKindToAttrString callInfo.callKind)) 
                            boxedArgsWithTypes []
```

### Function: `applyByStages` (line 1363)

Builds the actual papExtend MLIR operations:

```elm
applyByStages ctx funcVar funcMlirType sourceRemaining remainingStageArities saturatedReturnType callKindAttr args accOps =
    case args of
        [] -> return funcVar
        _ ->
            let
                batchSize = min sourceRemaining (List.length args)
                batch = List.take batchSize args
                rest = List.drop batchSize args
                
                -- MLIR papExtend attributes (line 1461-1476):
                baseAttrs =
                    [ ( "_operand_types", ArrayAttr ... )
                    , ( "remaining_arity", IntAttr Nothing sourceRemaining )  -- <-- THE BUG
                    , ( "newargs_unboxed_bitmap", IntAttr ... )
                    ]
```

**KEY LINE 1463**: The `remaining_arity` attribute is set to the `sourceRemaining` parameter passed to this function.

This `sourceRemaining` comes from `callInfo.initialRemaining` (line 1681), which was computed during GlobalOpt based on **static type analysis**, not **runtime closure arity**.

## The Bug

### Root Cause

For combinator-style functions like `b = s (k s) k`:

1. **GlobalOpt Phase**: 
   - Computes arity of `b` by analyzing the call `s (k s) k`
   - Determines that `s` has 3 parameters
   - After applying 2 args to `s`, result arity = 1
   - This arity (1) is stored in `varSourceArity[b]`
   - A wrapper closure is created with staging [1] (1 param per stage)

2. **Staging Rewriter Phase**:
   - The wrapper closure has the canonical staging [1]
   - When generating nested calls, it uses `initialRemaining = 1`

3. **Runtime Reality**:
   - `b` is actually a closure that takes 2 args and returns a function
   - When called as `b square inc 4`, it's called with 3 args
   - But the MLIR papExtend is annotated with `remaining_arity = 1`
   - This causes the runtime to apply only 1 arg, leaving `inc` and `4` as excess

### Why It's Wrong

The bug is in **assumption CGEN_052** (line 1421 in Expr.elm):

```elm
-- CGEN_052: remaining_arity is the SOURCE PAP's remaining, not the result's
remainingArity = sourceRemaining
```

This assumes the "source PAP" (the closure value at the call site) has the arity from the type.

But for composed closures:
- The **type** of `b` may say "takes 1 arg"
- The **actual closure header** says "takes 2 args" (from the original `s` function)
- The mismatch causes incorrect staging

### Location of Bug

The bug is in **GlobalOpt CallInfo computation** (MonoGlobalOptimize.elm):

When computing `initialRemaining` for a variable that's a partial application result (like `b`), the compiler should:

1. **Current (buggy)**: Use the first-stage arity from the variable's **type**
2. **Correct**: Use the actual arity from the **closure construction** (how many params the closure actually takes)

For combinator compositions, the static type flattening can produce a different staging than the original closure structure.

## Key Functions to Check

1. **`sourceArityForExpr`** (MonoGlobalOptimize.elm:1458)
   - Where `MonoVarLocal` looks up `varSourceArity`

2. **`varSourceArity` population**
   - Trace where `varSourceArity` dictionary is built
   - For let bindings with partial applications

3. **`closureBodyStageArities`** (MonoGlobalOptimize.elm:1656)
   - Should return the actual closure's param count, not the type's

4. **Staging Rewriter wrapper logic** (Staging/Rewriter.elm)
   - How wrappers compute their initial staging

## References

- **Invariants**: GOPT_010-016 (CallInfo post-conditions)
- **Design Docs**: `design_docs/invariants.csv` CGEN_052, CGEN_056
- **Test File**: `compiler/tests/TestLogic/Generate/CodeGen/PapExtendArity.elm`
- **MLIR Output**: Check `remaining_arity` attributes in generated MLIR
