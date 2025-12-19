Below is a concrete implementation plan for “fix (1): compute a concrete result type for binops in the typed optimizer” that an engineer can follow directly.

---

## 0. Goal (in one sentence)

Ensure that typed optimized binop calls like `(*)`, `(+), (-), (//)` never produce a `TVar "number"` result type when their operands have already been resolved to concrete `Int` or `Float`, so that `Case`/`If` etc. never carry `TVar "number"` in their `canType`.

---

## 1. Where to make changes

Work in the **typed** optimizer:

- File: `Compiler/Optimize/Typed/Expression.elm`  
  (this is the one that imports `KernelTypes.KernelTypeEnv` and constructs `TOpt.Expr`.)

There are two key spots:

1. The existing `Can.Binop` branch in `optimize` (general expression optimization).
2. (If present) any `Can.Binop` branch in `optimizeTail` or other helper functions in the same file.

You do **not** need to touch `Monomorphize.elm` or the MLIR backend for this fix.

---

## 2. Understand the current `Can.Binop` handling

Current code in `optimize` for binops looks like:

```elm
Can.Binop _ home name annotation left right ->
    let
        opType : Can.Type
        opType =
            annotationType annotation
    in
    Names.registerGlobal region home name opType
        |> Names.andThen
            (\optFunc ->
                optimize kernelEnv cycle annotations left
                    |> Names.andThen
                        (\optLeft ->
                            optimize kernelEnv cycle annotations right
                                |> Names.map
                                    (\optRight ->
                                        let
                                            resultType : Can.Type
                                            resultType =
                                                getCallResultType opType 2
                                        in
                                        TOpt.Call region optFunc [ optLeft, optRight ] resultType
                                    )
                        )
            )
``` 

- `opType` is the fully polymorphic operator type from the annotation (e.g. `number -> number -> number`).
- `getCallResultType opType 2` just peels off two `TLambda`s and returns the tail (for `(*)` that’s `TVar "number"`).
- That `TVar "number"` becomes the `canType` stored in the `TOpt.Call`, and later in containing expressions like `Case`.

We will replace the `resultType` computation with a helper that can use the already‑optimized operand types.

---

## 3. Add a helper to detect concrete numeric types

Near the existing basic type helpers, e.g. right after:

```elm
intType : Can.Type
intType =
    Can.TType ModuleName.basics "Int" []


floatType : Can.Type
floatType =
    Can.TType ModuleName.basics "Float" []
``` 

add:

```elm
{-| Check if a canonical type is a concrete numeric primitive (Int or Float). -}
isConcreteNumberType : Can.Type -> Bool
isConcreteNumberType tipe =
    case tipe of
        Can.TType home name [] ->
            home == ModuleName.basics
                && (name == Name.int || name == Name.float)

        _ ->
            False
```

Explanation:

- We only treat `Int` and `Float` with no type arguments as concrete numeric types.
- This lets us distinguish “fully resolved” numeric operands (good candidates for fixing `number`) from still‑polymorphic values (e.g. `TVar "number"`), where we fall back to the old behavior.

`ModuleName.basics`, `Name.int`, and `Name.float` are already used in this file, so no new imports should be needed.

---

## 4. Add a helper to compute binop result types

Near `getCallResultType`, add a new helper function:

### 4.1 Locate `getCallResultType`

You should find:

```elm
{-| Get the result type of a function call.
Peels off n TLambda wrappers.
-}
getCallResultType : Can.Type -> Int -> Can.Type
getCallResultType funcType numArgs =
    case ( funcType, numArgs ) of
        ( _, 0 ) ->
            funcType

        ( Can.TLambda _ result, n ) ->
            getCallResultType result (n - 1)

        _ ->
            -- Not enough lambdas - return what we have
            funcType
``` 

### 4.2 Add `computeBinopResultType` right after it

Insert:

```elm
{-| Compute the result type of a binary operator call.

This refines the old `getCallResultType opType 2` behavior for the common
case of numeric-supertype operators like (+), (-), (*), (//), etc.

If the operator's result type is the `number` supertype variable
(e.g. `number -> number -> number`) *and* both operands have already been
resolved to a concrete numeric type (`Int` or `Float`), we return that
concrete operand type instead of the abstract `TVar "number"`.

In all other cases, we fall back to `getCallResultType opType 2`.
-}
computeBinopResultType : Can.Type -> Can.Type -> Can.Type -> Can.Type
computeBinopResultType opType leftType rightType =
    let
        fallback : Can.Type
        fallback =
            getCallResultType opType 2
    in
    case opType of
        -- Expect a curried binary function: arg1 -> arg2 -> result
        Can.TLambda _ (Can.TLambda _ result) ->
            case result of
                -- Only special-case when the result is a numeric supertype var
                Can.TVar name ->
                    if Name.isNumberType name then
                        -- Only trust the operand type when it's a concrete number
                        if isConcreteNumberType leftType && leftType == rightType then
                            leftType

                        else
                            fallback

                    else
                        fallback

                _ ->
                    fallback

        _ ->
            -- Non-standard operator shapes: keep existing behavior
            fallback
```

Explanation:

- We pattern-match on `opType` as `arg1 -> arg2 -> result`. If we don’t see that form, we defer to the old logic.
- We only override the result when:
    - the operator’s result is `TVar name` and `Name.isNumberType name` (i.e., `number` supertype)  , and
    - both operand types are *already* the same concrete numeric primitive (`Int` or `Float`).
- If either operand is not concrete (e.g. still `TVar "number"` or some alias), we don’t change behavior; we keep whatever `getCallResultType` gave.
- For non‑numeric ops (like `<`, `++`, etc.), `result` is not `TVar "number"`, so this helper just falls back to `getCallResultType opType 2`, preserving existing behavior.

---

## 5. Use the helper in the `Can.Binop` branch

### 5.1 Update the main `optimize` function

Find the `Can.Binop` branch you saw earlier in `optimize` and replace the inner `let` block.

Current:

```elm
Can.Binop _ home name annotation left right ->
    let
        opType : Can.Type
        opType =
            annotationType annotation
    in
    Names.registerGlobal region home name opType
        |> Names.andThen
            (\optFunc ->
                optimize kernelEnv cycle annotations left
                    |> Names.andThen
                        (\optLeft ->
                            optimize kernelEnv cycle annotations right
                                |> Names.map
                                    (\optRight ->
                                        let
                                            resultType : Can.Type
                                            resultType =
                                                getCallResultType opType 2
                                        in
                                        TOpt.Call region optFunc [ optLeft, optRight ] resultType
                                    )
                        )
            )
``` 

Change the inner `let` to:

```elm
                                    (\optRight ->
                                        let
                                            leftType : Can.Type
                                            leftType =
                                                TOpt.typeOf optLeft

                                            rightType : Can.Type
                                            rightType =
                                                TOpt.typeOf optRight

                                            resultType : Can.Type
                                            resultType =
                                                computeBinopResultType opType leftType rightType
                                        in
                                        TOpt.Call region optFunc [ optLeft, optRight ] resultType
                                    )
```

Key points:

- We now use `TOpt.typeOf` to get the operand types from the already‑optimized subexpressions. This function exists and is already used elsewhere in this file.
- `computeBinopResultType` will:
    - return `Int` or `Float` directly for concrete numeric cases (fixing the `TVar "number"` leak), or
    - fall back to `getCallResultType` for everything else.

### 5.2 Make the same change in any other `Can.Binop` branches

Search within `Compiler/Optimize/Typed/Expression.elm` for additional `Can.Binop _ home name annotation` matches. There may or may not be another instance in `optimizeTail` or related tail‑optimization helpers.

For each such `Can.Binop` branch that currently does:

```elm
let
    opType = annotationType annotation
    ...
    resultType = getCallResultType opType 2
in
TOpt.Call ... resultType
```

update it to:

```elm
let
    opType = annotationType annotation
    ...
    leftType  = TOpt.typeOf optLeft
    rightType = TOpt.typeOf optRight
    resultType = computeBinopResultType opType leftType rightType
in
TOpt.Call ... resultType
```

The goal is that *all* typed binop calls in the typed optimizer consistently avoid propagating a raw `TVar "number"` result when operand types are concrete.

---

## 6. Why this fixes the original bug

With these changes:

- For `r * r` inside a branch where `r` is known to be `Int` (resp. `Float`), `optLeft` and `optRight` both have type `Can.TType ModuleName.basics "Int" []` (resp. `"Float"`).
- `opType` for `(*)` is still `number -> number -> number` from the annotation, so `result` in `computeBinopResultType` is `TVar "number"`.
- Since `Name.isNumberType "number"` is true and both operands are concrete numeric and equal, `computeBinopResultType` returns `leftType` (`Int` or `Float`), **not** `TVar "number"`.
- Therefore, the `TOpt.Call` for `r * r` has a concrete `canType` (`Int`/`Float`), and any enclosing `TOpt.Case` or `TOpt.If` expression will also end up with that concrete result type when `TOpt.typeOf` is used on the case/if expression.
- When `Monomorphize.applySubst` later sees that concrete type, it will not create `MVar "number" CNumber`. It will create `MInt`/`MFloat` directly for that position instead.
- Thus no `MVar _ CNumber` leaks into `Mono.MonoCase`’s result type, and `MLIR.monoTypeToMlir` no longer hits the `"MLIR codegen: unresolved type variable number - should have been instantiated"` crash.

---

## 7. Validation steps

After implementing the above, do the following:

1. **Rebuild** the compiler and run the existing test suite, especially:
    - Any tests that previously failed with the MLIR error  
      `"MLIR codegen: unresolved type variable number - should have been instantiated"`.
    - The “Unresolved Type Variable” test category documented in `PLAN.md` (AnonymousFunctionTest, or any `Case` tests that used numeric binops in branches).

2. **Inspect the typed optimized IR** (if you have a debug flag to dump `TOpt.Expr`) for a representative case such as:

   ```elm
   case shape of
       Circle r -> r * r
   ```

   Confirm that the `TOpt.Call` node for `r * r` has `canType = Int` (or `Float`) and that the `Case` expression’s `canType` is also concrete.

3. **Optional sanity checks**:
    - Verify that non‑numeric binops (e.g. `<`, `<=`, `++`) still get the correct result types (`Bool`, `String`, `List a`, etc.), since for them `computeBinopResultType` should just defer to `getCallResultType`.
    - Verify that generic functions that use `number` polymorphically but don’t appear in positions where the concrete type is already known (e.g. a fully polymorphic helper function) still behave as before.

If these pass, you’ve implemented fix (1) correctly and eliminated this source of `MVar _ CNumber` reaching MLIR codegen.

