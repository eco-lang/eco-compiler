# Investigation Report: TailDef Type Bug

## Summary

`TailDef` nodes in the TypedOptimized AST have malformed types for functions with explicit type annotations. This causes downstream issues in monomorphization where the canonical type from the definition doesn't match the expected monomorphized type from call sites.

**Symptom**: For a function like `sumHelper : Int -> Int -> Int`:
- `TailDef` args have types `[("acc", TVar "a"), ("n", TVar "a")]` instead of `[("acc", Int), ("n", Int)]`
- `TailDef` "return type" field is `Int -> Int -> Int` instead of `Int`

## Root Cause Analysis

There are **two distinct bugs**:

### Bug 1: Pattern types are unconstrained type variables

**Location**: `compiler/src/Compiler/Type/Constrain/Typed/Pattern.elm`, function `addWithIds` (lines 174-244)

**Problem**: For simple patterns like `PVar`, the code creates a fresh flex variable but never constrains it to match the expected type from the annotation.

**Code path for a TypedDef like `sumHelper : Int -> Int -> Int`**:

1. `typedArgsHelpWithIds` (Expression.elm:313-340) calls `Instantiate.fromSrcType rtv srcType` to convert the annotation type (`Int`) to an internal type (`AppN basics "Int" []`)

2. It creates an expectation: `PFromContext region (PTypedArg name index) argType`

3. It calls `Pattern.addWithIds pattern expected state nodeState`

4. In `addWithIds`, for `PVar`:
   - `patternNeedsConstraint` returns `False` (line 183-195 in Common.elm)
   - We go to the `else` branch (unconstrained path)
   - `extractVarFromType (getType expectation)` is called on `AppN basics "Int" []`
   - This returns `Nothing` because it's not a `VarN`
   - A new flex var is created via `mkFlexVar`
   - This var is recorded in `nodeState` for the pattern ID
   - **But NO constraint is added equating this var to `Int`!**

5. When the solver runs, this flex var is never unified with anything

6. When converting to `Can.Type` via `Type.toCanType`, the flex var becomes `TVar "a"`

**Evidence** (Pattern.elm:206-237):
```elm
else
    -- UNCONSTRAINED path: just record in NodeIds, no extra constraint or var in state
    let
        expectedType : Type
        expectedType =
            getType expectation
    in
    case extractVarFromType expectedType of
        Just existingVar ->
            -- Record the existing variable from expectation
            ...

        Nothing ->
            -- Fallback: create a var just for NodeIds tracking (unconstrained)
            -- PostSolve will need to compute the type from context
            Type.mkFlexVar
                |> IO.andThen
                    (\patVar ->
                        let
                            nodeState1 : NodeIds.NodeIdState
                            nodeState1 =
                                NodeIds.recordNodeVar patternInfo.id patVar nodeState0
                        in
                        -- Note: we do NOT add patVar to state.vars or add a constraint
                        addHelpWithIdsProg region patternInfo.node expectation state nodeState1
                            |> runPatternProgWithIds
                    )
```

The comment explicitly says "we do NOT add patVar to state.vars or add a constraint" and relies on PostSolve to fix this. But `postSolvePattern` (PostSolve.elm:253-314) does nothing for `PVar`:
```elm
Can.PVar _ ->
    ( nodeTypes0, kernel0 )
```

### Bug 2: Full function type passed as return type

**Location**: `compiler/src/Compiler/Optimize/Typed/Expression.elm`, function `optimizePotentialTailCall` (line 925)

**Problem**: When creating `TailDef`, the code passes `defType` (the full function type) as the last argument, which according to the type definition should be the return type.

**TailDef definition** (TypedOptimized.elm:277):
```elm
| TailDef A.Region Name (List ( A.Located Name, Can.Type )) Expr Can.Type
-- name, typed args, body, return type
```

**Creation code** (Expression.elm:925):
```elm
TOpt.TailDef region name argNamesWithTypes wrappedBody defType
```

For `sumHelper : Int -> Int -> Int`:
- `defType` is `Int -> Int -> Int` (the full function type from the annotation)
- But it should be `Int` (just the return type after peeling off argument types)

**Note**: The code does compute `bodyType = peelFunctionType (List.length args) defType` at line 914, but this is only used for the body optimization context, not for the TailDef's return type field.

## Impact

1. **Monomorphization**: When `specializeFunc` computes the monomorphized type from the `TailDef`'s canonical type, it produces a type with 4 arguments (`MFunction [MInt, MInt, MInt, MInt] MInt`) instead of 2 (`MFunction [MInt, MInt] MInt`)

2. **SpecId mismatch**: The workaround in the SpecId fix (using `requestedMonoType` instead of the recomputed type) masks this bug but doesn't fix it

3. **Type information loss**: The typed AST loses the correct concrete types for function parameters, which could affect other optimizations or analyses

## Proposed Fixes

### Fix for Bug 1 (Pattern types)

**Option A**: Add a constraint in the unconstrained path
```elm
Nothing ->
    Type.mkFlexVar
        |> IO.andThen
            (\patVar ->
                let
                    patType : Type
                    patType =
                        Type.VarN patVar

                    -- Add constraint: patVar = expectedType
                    eqCon : Type.Constraint
                    eqCon =
                        Type.CPattern region (patternToCategory patternInfo.node) patType expectation

                    (State headers vars revCons) =
                        state

                    stateWithPatVar : State
                    stateWithPatVar =
                        State headers (patVar :: vars) (eqCon :: revCons)

                    nodeState1 : NodeIds.NodeIdState
                    nodeState1 =
                        NodeIds.recordNodeVar patternInfo.id patVar nodeState0
                in
                addHelpWithIdsProg region patternInfo.node expectation stateWithPatVar nodeState1
                    |> runPatternProgWithIds
            )
```

**Option B**: Use the expected type's variable directly by instantiating it properly
- Ensure `Instantiate.fromSrcType` creates a type that `extractVarFromType` can extract from
- This would require changes to how concrete types like `Int` are represented

**Option C**: Fix in PostSolve
- Have `postSolvePattern` actually compute and record the pattern type
- This is more complex and may affect other code paths

### Fix for Bug 2 (Return type)

Change line 925 in Expression.elm from:
```elm
TOpt.TailDef region name argNamesWithTypes wrappedBody defType
```
To:
```elm
TOpt.TailDef region name argNamesWithTypes wrappedBody bodyType
```

Where `bodyType` is already computed at line 914:
```elm
bodyType =
    peelFunctionType (List.length args) defType
```

This ensures the "return type" field actually contains the return type.

## Verification Steps

After fixing:

1. Build the compiler: `cd /work/compiler && npm run build`

2. Run tests with the assertion restored in `specializeFunc`:
   ```elm
   if name == requestedName && monoTypeFromDef /= requestedMonoType then
       Utils.Crash.crash ("Type mismatch: from def = " ++ Debug.toString monoTypeFromDef ++ ", requested = " ++ Debug.toString requestedMonoType)
   else
       ...
   ```

3. Run full test suite: `cd /work/compiler && npx elm-test-rs --fuzz 10`

4. Specifically verify CGEN_044 tests pass

## Files to Modify

1. `compiler/src/Compiler/Type/Constrain/Typed/Pattern.elm` - Fix Bug 1
2. `compiler/src/Compiler/Optimize/Typed/Expression.elm` - Fix Bug 2

## Related Code

- `compiler/src/Compiler/Type/Constrain/Common.elm` - `patternNeedsConstraint`, `extractVarFromType`
- `compiler/src/Compiler/Type/PostSolve.elm` - `postSolvePattern`
- `compiler/src/Compiler/AST/TypedOptimized.elm` - `TailDef` definition
