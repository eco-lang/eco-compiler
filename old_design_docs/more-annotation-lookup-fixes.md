Below is a concrete implementation plan targeted at the remaining bad uses of `lookupAnnotationType` / `getDefNameAndType` for **local** `let rec` bindings in `Compiler/Optimize/Typed/Expression.elm`. The goal is:

- Only **top‑level** names ever go through `lookupAnnotationType` / `getDefNameAndType`.
- **Local** `let` / `let rec` defs get types from:
    - Their optimized RHS via `TOpt.typeOf` where possible.
    - Schematic function types built from patterns + type variables when we just need a shape to seed the environment.

All examples below are taken from the current `Expression.elm`    .

---

## 0. Invariant to keep in mind

Update comments (optional but recommended):

- Document that:

  ```elm
  lookupAnnotationType : Name -> Annotations -> Can.Type
  getDefNameAndType : Can.Def -> Annotations -> ( Name, Can.Type )
  ```

  are **only valid for top‑level definitions** that appear in the module’s `Annotations` map, not for locals.

This clarifies what we’re enforcing with the following code changes.

---

## 1. Fix `optimize`’s `Can.LetRec [def]` single‑def branch

### 1.1. Current behavior

In `optimize`, the `Can.LetRec` case has a “single def” fast path that still uses `getDefNameAndType` (which in turn calls `lookupAnnotationType`) even for **local** `let rec` bindings:

```elm
Can.LetRec defs body ->
    case defs of
        [ def ] ->
            optimizePotentialTailCallDef kernelEnv cycle annotations def
                |> Names.andThen
                    (\tailCallDef ->
                        let
                            -- Get the name and type from the def
                            ( defName, defType ) =
                                getDefNameAndType def annotations
                        in
                        Names.withVarType defName
                            defType
                            (optimize kernelEnv cycle annotations body)
                            |> Names.map
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody
                                    in
                                    TOpt.Let tailCallDef obody bodyType
                                )
                    )

        _ ->
            optimizeLetRecDefs kernelEnv cycle annotations defs body
```

For `let rec` inside a function, `defName` is local and not in `annotations`, so this can crash.

### 1.2. New behavior

Use the **typed def** returned by `optimizePotentialTailCallDef` as the source of `(name, type)` instead of annotations. That def is already typed (`TOpt.Def` or `TOpt.TailDef`).

**Change** the single‑def branch to:

```elm
Can.LetRec defs body ->
    case defs of
        [ def ] ->
            optimizePotentialTailCallDef kernelEnv cycle annotations def
                |> Names.andThen
                    (\tailCallDef ->
                        let
                            -- Extract name and type from the optimized def,
                            -- instead of using annotations.
                            ( defName, defType ) =
                                case tailCallDef of
                                    TOpt.Def _ name _ t ->
                                        ( name, t )

                                    TOpt.TailDef _ name _ _ t ->
                                        ( name, t )
                        in
                        Names.withVarType defName
                            defType
                            (optimize kernelEnv cycle annotations body)
                            |> Names.map
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody
                                    in
                                    TOpt.Let tailCallDef obody bodyType
                                )
                    )

        _ ->
            optimizeLetRecDefs kernelEnv cycle annotations defs body
```

**Why**: This keeps the optimization behavior (we still get a `TailDef` when appropriate) but removes reliance on annotations for local recursive defs.

---

## 2. Fix `optimizeLetRecDefs` (multi‑def `let rec`)

### 2.1. Current behavior

`optimizeLetRecDefs` currently seeds the environment by looking up each def’s type via `getDefNameAndType`:

```elm
optimizeLetRecDefs : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> List Can.Def -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeLetRecDefs kernelEnv cycle annotations defs body =
    -- For multiple recursive defs, we add all their types to scope first
    let
        defBindings : List ( Name, Can.Type )
        defBindings =
            List.map (\d -> getDefNameAndType d annotations) defs
    in
    Names.withVarTypes defBindings
        (List.foldl
            (\def bod ->
                Names.andThen (optimizeRecDefToLet kernelEnv cycle annotations def) bod
            )
            (optimize kernelEnv cycle annotations body)
            defs
        )
```

For local `let rec` inside a function, these defs have no annotations, so `getDefNameAndType` can crash.

### 2.2. New helper: `synthesizeRecDefType`

Add a helper near `getDefNameAndType` in `Expression.elm` to create a **schematic function type** for local recursive defs, without annotations:

```elm
{-| Synthesize a function type for a (possibly local) recursive def,
    without looking at annotations.

    For untyped defs, we build a `TLambda` chain with fresh type variables
    for each argument and the result. This is only used to seed the Names
    environment so recursive calls have some type; the final def type is
    computed later from the optimized RHS via TOpt.typeOf.
-}
synthesizeRecDefType : Can.Def -> Can.Type
synthesizeRecDefType def =
    case def of
        Can.Def (A.At _ name) args _ ->
            let
                -- One fresh type variable per arg, plus one for the result.
                argTypes : List Can.Type
                argTypes =
                    List.indexedMap
                        (\index _ ->
                            Can.TVar ("rec_arg_" ++ name ++ "_" ++ String.fromInt index)
                        )
                        args

                resultType : Can.Type
                resultType =
                    Can.TVar ("rec_result_" ++ name)
            in
            buildFunctionType argTypes resultType

        Can.TypedDef (A.At _ name) _ typedArgs _ resultType ->
            let
                argTypes : List Can.Type
                argTypes =
                    List.map Tuple.second typedArgs
            in
            buildFunctionType argTypes resultType
```

This does not touch `annotations` at all. It just gives “shape”: number of args and that it’s a function; unknown parts are proper type variables.

### 2.3. Use `synthesizeRecDefType` in `optimizeLetRecDefs`

Change `defBindings` to use this helper instead of `getDefNameAndType`:

```elm
optimizeLetRecDefs kernelEnv cycle annotations defs body =
    let
        defBindings : List ( Name, Can.Type )
        defBindings =
            List.map
                (\d ->
                    case d of
                        Can.Def (A.At _ name) _ _ ->
                            ( name, synthesizeRecDefType d )

                        Can.TypedDef (A.At _ name) _ _ _ _ ->
                            ( name, synthesizeRecDefType d )
                )
                defs
    in
    Names.withVarTypes defBindings
        (List.foldl
            (\def bod ->
                Names.andThen (optimizeRecDefToLet kernelEnv cycle annotations def) bod
            )
            (optimize kernelEnv cycle annotations body)
            defs
        )
```

**Why**:

- Recursive calls inside the group now see a function type of the right arity, with type variables for argument/result types.
- The *final* types written to `TOpt.Def` are still computed later from the optimized RHS via `TOpt.typeOf` (see next step), so we are not “lying” in the final IR; the schematic types only live in the local Names environment during optimization.

---

## 3. Fix `optimizeRecDefHelp` to infer from RHS instead of annotations

### 3.1. Current behavior

`optimizeRecDefHelp` still calls `lookupAnnotationType` for the def’s type:

```elm
optimizeRecDefHelp kernelEnv cycle annotations region name args expr body =
    let
        defType : Can.Type
        defType =
            lookupAnnotationType name annotations

        bodyType : Can.Type
        bodyType =
            TOpt.typeOf body
    in
    case args of
        [] ->
            optimize kernelEnv cycle annotations expr
                |> Names.map
                    (\oexpr ->
                        TOpt.Let (TOpt.Def region name oexpr defType) body bodyType
                    )

        _ ->
            destructArgs annotations args
                |> Names.andThen
                    (\( typedArgNames, destructors, bindings ) ->
                        ...
                        Names.withVarTypes allBindings
                            (optimize kernelEnv cycle annotations expr)
                            |> Names.map
                                (\oexpr ->
                                    let
                                        exprType : Can.Type
                                        exprType =
                                            TOpt.typeOf oexpr

                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) exprType
                                        ...
                                    in
                                    TOpt.Let (TOpt.Def region name ofunc funcType) body bodyType
                                )
                    )
```

For local recursive defs, `lookupAnnotationType` is invalid.

### 3.2. New behavior

Infer the def type from the optimized RHS (`TOpt.typeOf`) plus argument pattern types, exactly like you’ve already done for non‑recursive `let` in `optimizeDefHelp` .

Change `optimizeRecDefHelp` to:

```elm
optimizeRecDefHelp kernelEnv cycle annotations region name args expr body =
    let
        bodyType : Can.Type
        bodyType =
            TOpt.typeOf body
    in
    case args of
        [] ->
            -- No arguments: def type is just the RHS type.
            optimize kernelEnv cycle annotations expr
                |> Names.map
                    (\oexpr ->
                        let
                            defType : Can.Type
                            defType =
                                TOpt.typeOf oexpr
                        in
                        TOpt.Let (TOpt.Def region name oexpr defType) body bodyType
                    )

        _ ->
            destructArgs annotations args
                |> Names.andThen
                    (\( typedArgNames, destructors, bindings ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            allBindings : List ( Name, Can.Type )
                            allBindings =
                                argTypes ++ bindings
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv cycle annotations expr)
                            |> Names.map
                                (\oexpr ->
                                    let
                                        exprType : Can.Type
                                        exprType =
                                            TOpt.typeOf oexpr

                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) exprType

                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct exprType) oexpr destructors)
                                                funcType
                                    in
                                    TOpt.Let (TOpt.Def region name ofunc funcType) body bodyType
                                )
                    )
```

**Why**:

- For recursive defs, this makes their final `TOpt.Def` types consistent with the actual optimized body, same pattern as non‑recursive `let`/`let rec` paths.
- No annotations are used for locals; `lookupAnnotationType` is gone here.

Note: `optimizeTypedRecDefHelp` is already using the explicit `resultType` from the typed def and does *not* call `lookupAnnotationType`, so it can stay as‑is .

---

## 4. Refactor `optimizePotentialTailCall` and friends

The last problematic usage is in the tail‑call entrypoint itself.

### 4.1. Current behavior

`optimizePotentialTailCall` computes the function’s type by calling `lookupAnnotationType` on `name`:

```elm
optimizePotentialTailCall : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> A.Region -> Name -> List Can.Pattern -> Can.Expr -> Names.Tracker TOpt.Def
optimizePotentialTailCall kernelEnv cycle annotations region name args expr =
    let
        defType : Can.Type
        defType =
            lookupAnnotationType name annotations
    in
    destructArgs annotations args
        |> Names.andThen
            (\( typedArgNames, destructors, bindings ) ->
                let
                    ...
                    returnType : Can.Type
                    returnType =
                        getCallResultType defType (List.length args)
                in
                Names.withVarTypes allBindings
                    (optimizeTail kernelEnv cycle annotations name typedArgNames returnType expr)
                    |> Names.map (toTailDef region name typedArgNames destructors returnType)
            )
```

`optimizePotentialTailCallDef` just calls this for `Can.Def`, and is used from both:

- `Module.elm` (top‑level recursion; annotations are valid there).
- `Expression.optimize`’s local `Can.LetRec [def]` case, where annotations are *not* valid for the local name.

### 4.2. Change the API to take `defType` as an argument

Change the signature to:

```elm
optimizePotentialTailCall :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> A.Region
    -> Name
    -> Can.Type               -- defType, supplied by caller
    -> List Can.Pattern
    -> Can.Expr
    -> Names.Tracker TOpt.Def
```

And remove the internal `lookupAnnotationType`:

```elm
optimizePotentialTailCall kernelEnv cycle annotations region name defType args expr =
    destructArgs annotations args
        |> Names.andThen
            (\( typedArgNames, destructors, bindings ) ->
                let
                    argTypes : List ( Name, Can.Type )
                    argTypes =
                        List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                    allBindings : List ( Name, Can.Type )
                    allBindings =
                        argTypes ++ bindings

                    returnType : Can.Type
                    returnType =
                        getCallResultType defType (List.length args)
                in
                Names.withVarTypes allBindings
                    (optimizeTail kernelEnv cycle annotations name typedArgNames returnType expr)
                    |> Names.map (toTailDef region name typedArgNames destructors returnType)
            )
```

### 4.3. Update `optimizePotentialTailCallDef` to supply `defType` appropriately

`optimizePotentialTailCallDef` currently calls `optimizePotentialTailCall` without a type:

```elm
optimizePotentialTailCallDef kernelEnv cycle annotations def =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizePotentialTailCall kernelEnv cycle annotations region name args expr

        Can.TypedDef (A.At region name) _ typedArgs expr resultType ->
            optimizeTypedPotentialTailCall kernelEnv cycle annotations region name typedArgs expr resultType
```

Change it so:

- For **top‑level** defs (as seen from `Module.elm`), you still pass the type from annotations (valid there).
- For **local** defs (as seen from `Expression.optimize`), you pass a type synthesized from patterns.

You can implement this unconditionally using a helper, because for top‑level typed defs you can synthesize from `typedArgs` + `resultType` (which matches the annotation; no harm).

Example:

```elm
optimizePotentialTailCallDef kernelEnv cycle annotations def =
    case def of
        Can.Def (A.At region name) args expr ->
            let
                -- For untyped defs, synthesize a schematic type (see below).
                defType : Can.Type
                defType =
                    synthesizeRecDefType def
            in
            optimizePotentialTailCall kernelEnv cycle annotations region name defType args expr

        Can.TypedDef (A.At region name) _ typedArgs expr resultType ->
            let
                funcType : Can.Type
                funcType =
                    buildFunctionType (List.map Tuple.second typedArgs) resultType
            in
            optimizeTypedPotentialTailCall kernelEnv cycle annotations region name typedArgs expr resultType
```

**Note**: For `Can.Def`, `synthesizeRecDefType` (from step 2) returns a `TLambda` chain with TVars, which is enough for `getCallResultType` to compute a `returnType` of the right shape.

If you’d like, you can also add a special case when you *know* `def` is top‑level (in `Module.elm`) and use `lookupAnnotationType` there to get an exact canonical type; but from the perspective of `Expression.elm`, treating all defs uniformly via `synthesizeRecDefType` is acceptable and keeps the code simpler.

---

## 5. Final cleanup and verification

1. **Search for `lookupAnnotationType` and `getDefNameAndType` in `Expression.elm`.**

   After the above changes:

    - Allowed uses:
        - `Can.VarTopLevel home name` branch in `optimize` (global reference) .
    - Removed / replaced uses:
        - In `optimize`’s `Can.LetRec [def]` single‑def branch (replaced by reading from `TOpt.Def` / `TailDef`).
        - In `optimizeLetRecDefs` (`defBindings` now uses `synthesizeRecDefType`).
        - In `optimizeRecDefHelp` (now uses `TOpt.typeOf` on RHS and pattern types).
        - In `optimizePotentialTailCall` (now takes `defType` as a parameter).

2. **Ensure `Module.elm` still works for top‑level recursion.**

    - `addRecDefHelp` in `Compiler/Optimize/Typed/Module.elm` calls `Expr.optimizePotentialTailCallDef kernelEnv cycle annotations def` for top‑level defs; this now flows through `synthesizeRecDefType` / `buildFunctionType` instead of annotations for untyped top‑level defs, which is fine because:
        - For `Can.TypedDef`, it uses exact typed info.
        - For `Can.Def` without explicit annotation, there *is* an annotation stored in `annotations` already; if desired, you can special‑case top‑level defs in `optimizePotentialTailCallDef` to still use `lookupAnnotationType` there, but it isn’t necessary for correctness.

3. **Recompile and test:**

    - Re‑run the case that previously crashed with `"Annotation not found: res"` (the `foldrHelper`/`res` pattern).
    - Confirm:
        - No `lookupAnnotationType` is ever called with a local name.
        - The typed IR for local recursive functions has `TOpt.Def`/`TailDef` nodes whose function types are consistent with their bodies (RHS), as seen via `TOpt.typeOf`.
        - Tail‑call optimization still kicks in for both top‑level and local recursive defs.

---

By following these steps, you’ll have:

- Completely removed incorrect uses of `lookupAnnotationType` / `getDefNameAndType` for local bindings.
- Ensured that local `let` / `let rec` def types are derived from their patterns and optimized RHS (`TOpt.typeOf`), not from module annotations.
- Preserved the intended behavior of tail‑call optimization and recursive `let` desugaring.

