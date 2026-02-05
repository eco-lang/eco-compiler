# Fix generateCall Dispatch and applyByStages

## Problem Summary

Two related issues are causing test failures:

1. **generateCall dispatch change** routes ALL StageCurried calls through `generateClosureApplication`, losing intrinsic optimizations for core functions like `Basics.add`

2. **applyByStages remaining_arity reset** fix was lost, causing `remaining_arity` to go negative when crossing stage boundaries

## Root Cause Analysis

### Issue 1: Over-aggressive routing to closure path

The fix changed `generateCall` to:
```elm
case callModel of
    Ctx.FlattenedExternal -> ...
    Ctx.StageCurried -> generateClosureApplication ...  -- ALL stage-curried
```

But `generateClosureApplication` doesn't have the intrinsic matching logic that `generateSaturatedCall` has for core functions (`Basics.add`, `Basics.sub`, etc.).

Result: `\a b -> a + b` now generates:
```mlir
%2 = "eco.papCreate"() {arity = 2, function = @Basics_add_$_8, ...}
%3 = "eco.papExtend"(%2, %a) ...
%4 = "eco.papExtend"(%3, %b) ...
```
Instead of:
```mlir
%2 = "eco.int.add"(%a, %b) : (i64, i64) -> i64
```

### Issue 2: Stale resultType still used for return type

Even with call model dispatch, `generateClosureApplication` still uses the stale `resultType` from `MonoCall` when computing return types and in `applyByStages`.

### Issue 3: applyByStages doesn't reset at stage boundaries

When a stage is fully applied (remaining=0), the result is a NEW closure with its own arity. The current code:
```elm
resultRemaining = sourceRemaining - batchSize
```
Goes negative instead of resetting to the new closure's arity.

## Solution

### Step 1: Fix generateCall dispatch to use arity comparison

Instead of routing ALL StageCurried calls to closure path, compare args to signature arity:
- If `args.length >= totalArity` (saturated): use `generateSaturatedCall` (has intrinsics)
- If `args.length < totalArity` (partial): use `generateClosureApplication`

This preserves intrinsic optimizations while correctly handling partial applications.

```elm
generateCall ctx func args resultType =
    let
        callModel =
            callModelForCallee ctx func
    in
    case callModel of
        Ctx.FlattenedExternal ->
            -- Kernels/externs: use original logic
            if Types.isFunctionType resultType then
                generateClosureApplication ctx func args resultType
            else
                generateSaturatedCall ctx func args resultType

        Ctx.StageCurried ->
            -- User functions: compare arg count to signature arity
            let
                totalArity =
                    case func of
                        Mono.MonoVarGlobal _ specId _ ->
                            case Dict.get specId ctx.signatures of
                                Just sig ->
                                    -- Total arity = first stage params + countTotalArity of returnType
                                    List.length sig.paramTypes + Types.countTotalArity sig.returnType

                                Nothing ->
                                    Types.countTotalArity (Mono.typeOf func)

                        _ ->
                            Types.countTotalArity (Mono.typeOf func)
            in
            if List.length args >= totalArity then
                -- Saturated call: use saturated path (has intrinsic logic)
                generateSaturatedCall ctx func args resultType
            else
                -- Partial application: use closure path
                generateClosureApplication ctx func args resultType
```

### Step 2: Restore applyByStages remaining_arity reset

When `rawResultRemaining <= 0` and `stageRetType` is a function type, reset to the new closure's arity:

```elm
rawResultRemaining =
    sourceRemaining - batchSize

resultRemaining =
    if rawResultRemaining <= 0 then
        -- Stage fully applied - result is a new closure
        -- Use the return type's arity as the new source remaining
        Types.countTotalArity stageRetType
    else
        rawResultRemaining
```

## Implementation Steps

1. Edit `generateCall` in `Expr.elm` to use arity-based dispatch for StageCurried
2. Restore the `applyByStages` fix for remaining_arity reset
3. Compile and run tests
4. Verify MLIR output shows correct intrinsics and remaining_arity values

## Files to Modify

- `/work/compiler/src/Compiler/Generate/MLIR/Expr.elm`
  - `generateCall` function (~line 915)
  - `applyByStages` function (~line 1036)

## Expected Outcome

- Core function calls (`Basics.add`, etc.) generate intrinsics like `eco.int.add`
- Partial applications route through closure path with correct staging
- `remaining_arity` resets correctly at stage boundaries (no negative values)
- All Lambda tests pass
