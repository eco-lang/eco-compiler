# Fix TailRec SSA collision and ABI boxing

## Problem

Two related MLIR codegen bugs in tail-recursive lambdas:

1. **SSA collision (`TailRecDeciderSearchTest`)**: When a tail-recursive lambda is created from a let-rec group, `generateLambdaFunc` resets `nextVar` to `List.length allArgPairs`. This can produce `%1` for a local `i1` constant that collides with `%1 : !eco.value` in `siblingMappings`.

2. **ABI type mismatch (`TailRecBoolCarryTest`)**: `compileTailCallStep` forwards raw SSA types (e.g. `i1` for Bool `True`) into `nextParams`, but the `scf.while` loop state expects ABI types (e.g. `!eco.value` for Bool). This causes `eco.yield` type mismatches.

## Resolved Questions

All questions from the initial review have been resolved:

1. **`String.toInt` API**: Returns `Maybe Int` in this codebase (stock Elm). No `Result.toMaybe` needed.

2. **`ctx.nextVar` propagation**: Confirmed — `processLambdas` threads context through a fold, so `newCtx` from each `generateLambdaFunc` becomes `accCtx` for the next sibling. The shared allocator works as intended.

3. **Named vs numeric SSA collisions**: Not a concern. `freshVar` only produces numeric `%N`. Named parameters (`%found`, `%firstInlineExpr`) are built directly from Elm names and live in separate `func.func` SSA scopes.

4. **`List.maximum` on empty list**: Safe — the list always has at least one element (`ctx.nextVar`). Empty `siblingMappings` yields `maxSiblingIndex = -1`, so `fromSiblings = 0`.

5. **Arity mismatch fallback**: Should `crash` loudly rather than silently falling back, since `MonoTailCall` arity must match `loopSpec.paramVars` by IR invariant.

6. **Other callers of `compileTailCallStep`**: Only called from `compileStep` on `Mono.MonoTailCall`. Coercion is a no-op when types already match.

7. **Return value coercion**: Already handled — `compileBaseReturnStep` calls `coerceResultToType` for `loopSpec.retType`. No additional coercion needed for the result, only for `nextParams`.

## Plan

### Part A: Shared SSA allocator across sibling lambdas

**File**: `compiler/src/Compiler/Generate/MLIR/Lambdas.elm`
**Function**: `generateLambdaFunc` (lines 82-262)

#### Step 1: Add `parseNumericIndex` helper

Inside `generateLambdaFunc`'s `let` block, add a local helper that extracts the numeric index from SSA names like `"%0"`, `"%1"`, `"%42"`:

```elm
parseNumericIndex : String -> Maybe Int
parseNumericIndex ssaName =
    if String.startsWith "%" ssaName then
        String.dropLeft 1 ssaName |> String.toInt
    else
        Nothing
```

`String.toInt` returns `Maybe Int` directly — no `Result.toMaybe`.

#### Step 2: Compute `maxSiblingIndex`

```elm
maxSiblingIndex : Int
maxSiblingIndex =
    lambda.siblingMappings
        |> Dict.values
        |> List.filterMap (\info -> parseNumericIndex info.ssaVar)
        |> List.maximum
        |> Maybe.withDefault -1
```

#### Step 3: Compute `nextVarBase` (replaces `nextVarAfterParams`)

```elm
nextVarBase : Int
nextVarBase =
    List.maximum [ ctx.nextVar, List.length allArgPairs, maxSiblingIndex + 1 ]
        |> Maybe.withDefault 0
```

This ensures `nextVar` is never moved backwards relative to the enclosing context, and is always past any numeric `%N` in `siblingMappings`.

#### Step 4: Use `nextVarBase` in `ctxWithArgs`

Replace:
```elm
ctxWithArgs = { ctx | varMappings = varMappingsWithSiblings, nextVar = nextVarAfterParams }
```
With:
```elm
ctxWithArgs = { ctx | varMappings = varMappingsWithSiblings, nextVar = nextVarBase }
```

Remove the now-unused `nextVarAfterParams` binding.

---

### Part B: Tail loop ABI boxing fix

**File**: `compiler/src/Compiler/Generate/MLIR/TailRec.elm`
**Function**: `compileTailCallStep` (lines 374-415)

#### Step 1: Build `paramTypes` array from `loopSpec.paramVars`

At the start of `compileTailCallStep`, before the fold:
```elm
paramTypes : Array MlirType
paramTypes =
    loopSpec.paramVars
        |> List.map Tuple.second
        |> Array.fromList
```

`Array` is already imported in this file.

#### Step 2: Replace the argument fold with coercion

Replace the existing fold with one that evaluates each argument, looks up the expected ABI type, and coerces:

```elm
( argOpsRev, argVarsRev, ctx1 ) =
    List.foldl
        (\( index, ( _, argExpr ) ) ( opsAcc, varsAcc, ctxAcc ) ->
            let
                argResult =
                    Expr.generateExpr ctxAcc argExpr

                expectedTy : MlirType
                expectedTy =
                    case Array.get index paramTypes of
                        Just ty ->
                            ty

                        Nothing ->
                            crash
                                ("TailRec.compileTailCallStep: arity mismatch for tail call in "
                                    ++ loopSpec.funcName
                                )

                ( coerceOps, finalVar, ctxCoerced ) =
                    Expr.coerceResultToType
                        argResult.ctx
                        argResult.resultVar
                        argResult.resultType
                        expectedTy

                chunkOps =
                    argResult.ops ++ coerceOps
            in
            ( List.reverse chunkOps ++ opsAcc
            , ( finalVar, expectedTy ) :: varsAcc
            , ctxCoerced
            )
        )
        ( [], [], ctx )
        (List.indexedMap Tuple.pair args)

argOps =
    List.reverse argOpsRev

argVars =
    List.reverse argVarsRev
```

Key behaviors:
- Bool `i1` → `!eco.value`: inserts `eco.box`
- `!eco.value` → primitive: inserts unbox
- Same types: no-op (most common case)
- Arity mismatch: `crash` (IR invariant violation)

#### No other changes needed

- `buildAfterRegion` already updates `loopSpec.paramVars` with after-region block args that have correct ABI types from `stateTypes`
- The done/dummy result logic at the end of `compileTailCallStep` is unchanged
- No new imports needed (`Expr` and `Array` are already imported)
- Return value coercion is already handled by `compileBaseReturnStep`
- `compileTailCallStep` is only called from `compileStep` on `Mono.MonoTailCall`

## Files Modified

| File | Function | Change |
|------|----------|--------|
| `compiler/src/Compiler/Generate/MLIR/Lambdas.elm` | `generateLambdaFunc` | Shared SSA allocator via `nextVarBase` |
| `compiler/src/Compiler/Generate/MLIR/TailRec.elm` | `compileTailCallStep` | Coerce tail-call args to ABI types |

## Testing

```bash
# Elm frontend tests
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1

# Full E2E (includes MLIR verification)
cmake --build build --target check

# Targeted
TEST_FILTER=TailRec cmake --build build --target check
```
