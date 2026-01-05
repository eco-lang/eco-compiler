Here’s a concrete, implementation‑level plan to fix the `"Annotation not found: res"` crash without hacks, structured so an engineer can follow it step‑by‑step.

The core idea is:

- **Annotations are only for top‑level defs.**
- **Local `let` / `let rec` bindings must get their type from the optimized RHS (`TOpt.typeOf`) or from the resulting `TOpt.Def`, never from `annotations`.**

All file references below are to `Compiler/Optimize/Typed/Expression.elm` unless otherwise noted.

---

## 0. Establish the invariant

Before changing code, it helps to document the intended invariant:

1. `lookupAnnotationType` and `getDefNameAndType` are only valid for definitions that have a top‑level annotation (module defs, ports, etc.).  
   Current implementation of `getDefNameAndType` uses `lookupAnnotationType` for `Can.Def` :

   ```elm
   getDefNameAndType : Can.Def -> Annotations -> ( Name, Can.Type )
   getDefNameAndType def annotations =
       case def of
           Can.Def (A.At _ name) _ _ ->
               ( name, lookupAnnotationType name annotations )

           Can.TypedDef (A.At _ name) _ typedArgs _ resultType ->
               ...
   ```

2. Local `let` bindings (like your `res` inside `foldrHelper`) are represented as `Can.Let def body` in `optimize` / `optimizeTail`. For them, there is **no annotation**, by language design.

We’ll make all local‑def logic adhere to this invariant.

---

## 1. Fix `optimizeTail`’s `Can.Let` branch

### 1.1. Locate the current `Can.Let` logic in `optimizeTail`

Search for `optimizeTail` and the `Can.Let` branch. You should find this shape :

```elm
optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType ((A.At region expression) as locExpr) =
    case expression of
        ...
        Can.Let def body ->
            let
                ( defName, defType ) =
                    getDefNameAndType def annotations
            in
            case def of
                Can.Def (A.At defRegion _) defArgs defExpr ->
                    optimizeDefForTail kernelEnv cycle annotations defRegion defName defArgs defExpr defType
                        |> Names.andThen
                            (\odef ->
                                Names.withVarType defName
                                    defType
                                    (optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType body)
                                    |> Names.map
                                        (\obody ->
                                            let
                                                bodyType : Can.Type
                                                bodyType =
                                                    TOpt.typeOf obody
                                            in
                                            TOpt.Let odef obody bodyType
                                        )
                            )

                Can.TypedDef (A.At defRegion _) _ defTypedArgs defExpr defResultType ->
                    optimizeTypedDefForTail kernelEnv cycle annotations defRegion defName defTypedArgs defExpr defResultType
                        |> Names.andThen
                            (\odef ->
                                Names.withVarType defName
                                    defType
                                    (optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType body)
                                ...
```

The **bug** is the use of `getDefNameAndType` for *local* `def` here. For untyped `Can.Def`, that calls `lookupAnnotationType`, which crashes on `res` because `res` is not in the top‑level `annotations` map.

### 1.2. Change `optimizeDefForTail` to not require `defType`

We’ll reuse the same “infer type from RHS” pattern that `optimizeDefHelp` uses for regular `let` bindings .

**Current signature & implementation** :

```elm
optimizeDefForTail :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> Can.Expr
    -> Can.Type            -- defType from annotations
    -> Names.Tracker TOpt.Def
optimizeDefForTail kernelEnv cycle annotations region name args expr defType =
    case args of
        [] ->
            optimize kernelEnv cycle annotations expr
                |> Names.map
                    (\oexpr ->
                        TOpt.Def region name oexpr defType
                    )

        _ ->
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
                            (optimize kernelEnv cycle annotations expr)
                            |> Names.map
                                (\oexpr ->
                                    let
                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) returnType
                                        ...
                                    in
                                    TOpt.Def region name ofunc funcType
                                )
                    )
```

**Change it to compute types from the optimized RHS instead of `defType`:**

New signature (drop `defType`):

```elm
optimizeDefForTail :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> Can.Expr
    -> Names.Tracker TOpt.Def
```

New implementation:

```elm
optimizeDefForTail kernelEnv cycle annotations region name args expr =
    case args of
        [] ->
            -- Simple value binding: infer its type from the RHS
            optimize kernelEnv cycle annotations expr
                |> Names.map
                    (\oexpr ->
                        let
                            exprType : Can.Type
                            exprType =
                                TOpt.typeOf oexpr
                        in
                        TOpt.Def region name oexpr exprType
                    )

        _ ->
            -- Function binding: infer arg and return types from patterns + RHS
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
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf oexpr

                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) bodyType

                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction
                                                typedArgNames
                                                (List.foldr (wrapDestruct bodyType) oexpr destructors)
                                                funcType
                                    in
                                    TOpt.Def region name ofunc funcType
                                )
                    )
```

Notes:

- This mirrors the structure used in `optimizeDefHelp` for non‑tail `let` defs, which also infers `bodyType` and builds `funcType` from it .
- No annotations are consulted for local defs.

Update any type annotations and the module’s `exposing` section if `optimizeDefForTail` is exported.

### 1.3. Update `optimizeTail`’s `Can.Let` branch to stop using `getDefNameAndType`

After changing `optimizeDefForTail`’s type, update the `Can.Let` branch to:

1. Pattern match on `def` to get the name.
2. Use `optimizeDefForTail` (new version, no `defType` parameter) or `optimizeTypedDefForTail` for typed defs.
3. Extract the type from the resulting `TOpt.Def` and put that into the local type environment.

**New code sketch:**

Replace the existing `Can.Let` branch with something like:

```elm
Can.Let def body ->
    case def of
        Can.Def (A.At defRegion defName) defArgs defExpr ->
            optimizeDefForTail kernelEnv cycle annotations defRegion defName defArgs defExpr
                |> Names.andThen
                    (\odef ->
                        let
                            defType : Can.Type
                            defType =
                                case odef of
                                    TOpt.Def _ _ _ t ->
                                        t

                                    TOpt.TailDef _ _ _ _ t ->
                                        -- In practice we won't produce TailDef for a local let here,
                                        -- but handling it defensively keeps this total.
                                        t
                        in
                        Names.withVarType defName
                            defType
                            (optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType body)
                            |> Names.map
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody
                                    in
                                    TOpt.Let odef obody bodyType
                                )
                    )

        Can.TypedDef (A.At defRegion defName) _ defTypedArgs defExpr defResultType ->
            optimizeTypedDefForTail kernelEnv cycle annotations defRegion defName defTypedArgs defExpr defResultType
                |> Names.andThen
                    (\odef ->
                        let
                            defType : Can.Type
                            defType =
                                case odef of
                                    TOpt.Def _ _ _ t ->
                                        t

                                    TOpt.TailDef _ _ _ _ t ->
                                        t
                        in
                        Names.withVarType defName
                            defType
                            (optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType body)
                            |> Names.map
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody
                                    in
                                    TOpt.Let odef obody bodyType
                                )
                    )
```

Key points:

- **No call to `getDefNameAndType`** here anymore, hence no `lookupAnnotationType` for local defs.
- `defType` now comes from the typed optimized def (`TOpt.Def` or `TOpt.TailDef`), which is the canonical source of truth in this phase.

---

## 2. Fix the `Can.LetRec` single‑def branch in `optimizeTail`

The `LetRec` single‑def special case is for recursive functions that we recognize and transform into `TailDef`. In this case, the def *is* top‑level when called from module optimization, but we can still avoid hitting annotations and instead trust the typed def.

Current code in `optimizeTail` :

```elm
Can.LetRec defs body ->
    case defs of
        [ def ] ->
            optimizePotentialTailCallDef kernelEnv cycle annotations def
                |> Names.andThen
                    (\odef ->
                        let
                            ( defName, defType ) =
                                getDefNameAndType def annotations
                        in
                        Names.withVarType defName
                            defType
                            (optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType body)
                            |> Names.map
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody
                                    in
                                    TOpt.Let odef obody bodyType
                                )
                    )

        _ ->
            -- Multiple recursive defs - fall back to regular optimization
            optimizeLetRecDefs kernelEnv cycle annotations defs body
```

Change the single‑def case to derive the type from `odef` instead of `getDefNameAndType`:

```elm
Can.LetRec defs body ->
    case defs of
        [ def ] ->
            optimizePotentialTailCallDef kernelEnv cycle annotations def
                |> Names.andThen
                    (\odef ->
                        let
                            ( defName, defType ) =
                                case odef of
                                    TOpt.Def _ name _ t ->
                                        ( name, t )

                                    TOpt.TailDef _ name _ _ t ->
                                        ( name, t )
                        in
                        Names.withVarType defName
                            defType
                            (optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType body)
                            |> Names.map
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody
                                    in
                                    TOpt.Let odef obody bodyType
                                )
                    )

        _ ->
            optimizeLetRecDefs kernelEnv cycle annotations defs body
```

Benefits:

- The tail‑call optimized def is already typed; using it avoids any reliance on annotations.
- This also makes the code robust if you ever produce a `LetRec` in a context where annotations aren’t available, though today this primarily hits top‑level recursive groups.

---

## 3. Fix `optimizeLetRecDefs` / `optimizeRecDefHelp` for recursive groups

`optimizeLetRecDefs` is used in the non‑tail path to rewrite recursive `LetRec` into nested `Let`s with typed defs. It currently seeds the type environment using `getDefNameAndType` (annotations) and also uses `lookupAnnotationType` inside `optimizeRecDefHelp` :

```elm
optimizeLetRecDefs kernelEnv cycle annotations defs body =
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

And `optimizeRecDefHelp`:

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
            ...
            Names.withVarTypes allBindings
                (optimize kernelEnv cycle annotations expr)
                |> Names.map
                    (\oexpr ->
                        ...
                        funcType =
                            buildFunctionType (List.map Tuple.second typedArgNames) exprType
                        ...
                        TOpt.Let (TOpt.Def region name ofunc funcType) body bodyType
                    )
```

These defs are exactly the ones in a recursive group, and at the module level they **do** have annotations, so this isn’t crashing today. But you can still cleanly make them annotation‑independent in the same way:

### 3.1. Stop using `getDefNameAndType` in `optimizeLetRecDefs`

Change the `defBindings` computation to look at the resulting `TOpt.Def`s instead of annotations.

One simple approach is:

1. First, optimize all defs with `optimizeRecDefToLet` in a pass that collects their `TOpt.Def`s.
2. Compute bindings from those defs using pattern matching on `TOpt.Def` / `TOpt.TailDef`.
3. Then optimize the body using those bindings.

But given that `optimizeRecDefToLet` takes a `TOpt.Expr` body and returns a new `TOpt.Expr`, and we already know the recursive defs are top‑level (and therefore annotated), you can leave this for later if you want to keep the change minimal.

If you *do* want to eliminate annotation usage here as well, I’d:

- Introduce a small helper `defTypeOf : TOpt.Def -> (Name, Can.Type)`.
- When building the cycle in `Module.elm`, you already get `TOpt.Def`s (or `TailDef`s) via `Expr.optimizePotentialTailCallDef` etc; you can push those into the environment directly. This is more involved, so for this bug specifically you can leave `optimizeLetRecDefs` as‑is, since the crash is on a *local* let, not a `LetRec`.

**For the scope of your current bug, you can leave this unchanged** and revisit later if you want a stricter “no annotations past module boundary” invariant.

---

## 4. Leave top‑level uses of `lookupAnnotationType` intact

There are places where annotations are the right source of truth:

- `Can.VarTopLevel home name` in `optimize` uses `lookupAnnotationType` to get the type of a global function from the annotation map .
- `optimizePotentialTailCall` uses `lookupAnnotationType` for the *root* top‑level function being tail‑optimized, in order to compute `returnType` via `getCallResultType` .
- `Module.elm` uses `lookupAnnotationType` for ports and defs when building the optimized graph; these are all top‑level and annotated by construction  .

You **do not need to touch these**; they are correct and won’t hit local names like `res`.

If you like, add a brief comment above `lookupAnnotationType` and `getDefNameAndType` explaining that they are **only** intended for top‑level definitions with annotations:

```elm
{-| Look up the canonical type of a top-level definition from its annotation.
    Do not use this for local let/letrec bindings; those must be typed via TOpt.typeOf.
-}
lookupAnnotationType : Name -> Annotations -> Can.Type
...
```

and similarly for `getDefNameAndType`.

---

## 5. Sanity checks and tests

After implementing the changes above:

1. **Recompile and run existing tests / sample projects.**

2. Specifically test the scenario that triggered the bug:

   - A recursive function like `foldrHelper` whose body has a local `let`:

     ```elm
     foldrHelper fn acc ctr r4 =
         let
             res =
                 if ctr > 500 then
                     -- some chunked recursion
                 else
                     foldrHelper fn acc (ctr + 1) r4
         in
         fn a (fn b (fn c (fn d res)))
     ```

   - With typed optimization turned on, this should no longer crash with `"Annotation not found: res"`. Instead, `res` will get a type from the optimized RHS via `TOpt.typeOf`, and subsequent `VarLocal res` uses will see that type in `Names.Context`.

3. Inspect the generated typed IR for this function, confirming:

   - A `TOpt.Let` binding for `res` whose `TOpt.Def` carries a sensible `Can.Type`.
   - No `TailCall` is generated for `res` itself (only for the root function if applicable).

4. Spot‑check a recursive top‑level function that *does* get tail‑call optimized to ensure `optimizePotentialTailCall` and `optimizeTail` still produce `TailDef` and `TailCall` nodes with consistent types.

---

## 6. Summary of concrete edits

For quick reference:

- **In `Expression.elm`**:

  1. Change `optimizeDefForTail` signature to drop the `Can.Type` parameter and rewrite it to infer types via `TOpt.typeOf` .
  2. Rewrite the `Can.Let` branch of `optimizeTail` to:
     - Pattern match on `Can.Def` / `Can.TypedDef`.
     - Call `optimizeDefForTail` / `optimizeTypedDefForTail`.
     - Extract `(defName, defType)` from the resulting `TOpt.Def`/`TailDef`.
     - Use `Names.withVarType defName defType` for the body.
     - Remove the `getDefNameAndType` usage entirely in this branch.
  3. Rewrite the single‑def `Can.LetRec` branch of `optimizeTail` to take `(defName, defType)` from `odef` instead of `getDefNameAndType` .
  4. Optionally, document that `lookupAnnotationType` and `getDefNameAndType` are for top‑level defs only.

With these changes, all local bindings in tail‑optimization paths will be typed via inference on the optimized RHS, matching the behavior of the regular optimizer and eliminating the `"Annotation not found: res"` crash without introducing fallbacks or placeholders.

