Here’s a concrete, engineer‑oriented implementation plan that ties directly to the current code.

All paths below are in the compiler source you showed (e.g. `Compiler/Optimize/Typed/Expression.elm` etc.).

---

## 0. Goal / high‑level design

We want:

1. Every pattern‑bound local (including nested ones from tuples, lists, constructors, etc.) to be added to the typed `Names` context with a `Can.Type`.
2. All code paths that introduce pattern variables (function args, `let`‑destructs, `case` branches) to use that information.

We’ll do this by:

- Making a single “pattern → destructors + bindings” helper the *source of truth*.
- Having all higher‑level helpers (`destructArgs`, `destructCaseWithType`, `destructWithKnownType`, etc.) call that.
- Updating the places where we call `Names.withVarType(s)` to include nested bindings, not just top‑level arg names.

Most of the changes live in `Compiler/Optimize/Typed/Expression.elm`.

---

## 1. Refactor destruct helpers: one core that always collects bindings

### 1.1. Locate the current destruct helpers

In `Compiler/Optimize/Typed/Expression.elm`, find the “DESTRUCTURING” section for the typed optimizer. You should see:

- `destructArgs`, `destructTypedArgs`, `destructTypedArg`
- `destructCase`, `destructCaseWithType`
- `destruct`, `destructWithType`, `destructWithKnownType`, `getPatternType`
- `destructHelp` and `destructHelpCollectBindings` at the bottom of that section.

Right now:

- `destructHelp` covers all pattern forms and returns only destructors.
- `destructHelpCollectBindings` handles only `PAnything`, `PVar`, `PRecord`, `PAlias`, and falls back to `destructHelp` for everything else (PTuple, PList, PCons, PCtor, etc.), dropping bindings.

### 1.2. Make `destructHelpCollectBindings` the core

Refactor so that **`destructHelpCollectBindings` becomes the single, complete implementation**, and `destructHelp` becomes a small wrapper around it.

1. Keep the signature:

   ```elm
   destructHelpCollectBindings
       : TOpt.Path
       -> Can.Type
       -> Can.Pattern
       -> ( List TOpt.Destructor, List ( Name, Can.Type ) )
       -> Names.Tracker ( List TOpt.Destructor, List ( Name, Can.Type ) )
   ```

   This pair `(revDs, bindings)` is your accumulator:
    - `revDs` – reverse‑order destructors (same semantics as `destructHelp` currently).
    - `bindings` – `(Name, Can.Type)` pairs for every bound variable.

2. Replace its body with a *complete* pattern match that mirrors `destructHelp`’s cases, but:

    - Always recurses into **`destructHelpCollectBindings`** itself (never back into `destructHelp`).
    - Whenever a variable becomes visible in scope, append `(name, itsType)` to `bindings`.

   Concretely:

    - **Wildcard**:

      ```elm
      Can.PAnything ->
          Names.pure ( revDs, bindings )
      ```

    - **Plain variable**:

      ```elm
      Can.PVar name ->
          Names.pure
              ( TOpt.Destructor name path tipe :: revDs
              , ( name, tipe ) :: bindings
              )
      ```

      This mirrors the existing case, just ensure you remove later fallback to `destructHelp`.

    - **Record pattern**: use `getFieldType` and mirror existing `destructHelp` logic, but also bind each field:

      ```elm
      Can.PRecord fields ->
          let
              newBindings =
                  List.map (\f -> ( f, getFieldType f tipe )) fields
 
              toDestruct name =
                  TOpt.Destructor name (TOpt.Field name path) (getFieldType name tipe)
          in
          Names.registerFieldList fields
              ( List.map toDestruct fields ++ revDs
              , newBindings ++ bindings
              )
      ```

    - **Alias** (`pat as name`):

        - The alias introduces a new variable bound to the *whole* value of type `tipe`.
        - Reuse the pattern from the existing `Can.PAlias` branch, but recurse via `destructHelpCollectBindings`:

      ```elm
      Can.PAlias subPattern name ->
          destructHelpCollectBindings (TOpt.Root name) tipe subPattern
              ( TOpt.Destructor name path tipe :: revDs
              , ( name, tipe ) :: bindings
              )
      ```

    - **Unit**:

      ```elm
      Can.PUnit ->
          Names.pure ( revDs, bindings )
      ```

    - **Tuples**:

      Reuse the type‑splitting logic already in `destructHelp` and `destructTwo`. E.g. for 2‑tuple:

      ```elm
      Can.PTuple a b [] ->
          -- similar to destructTwo, but with bindings
          let
              ( aType, bType ) =
                  case tipe of
                      Can.TTuple t1 t2 [] -> ( t1, t2 )
                      _ -> crash "Type mismatch in 2-tuple pattern"
          in
          case path of
              TOpt.Root _ ->
                  destructHelpCollectBindings (TOpt.Index Index.first path) aType a ( revDs, bindings )
                      |> Names.andThen
                          (\( revDs1, bindings1 ) ->
                              destructHelpCollectBindings (TOpt.Index Index.second path) bType b ( revDs1, bindings1 )
                          )
 
              _ ->
                  -- mirror existing pattern: generate temp root, add a root destructor,
                  -- then recurse using that root
                  Names.generate
                      |> Names.andThen
                          (\name ->
                              let
                                  newRoot = TOpt.Root name
                              in
                              destructHelpCollectBindings (TOpt.Index Index.first newRoot) aType a
                                  ( TOpt.Destructor name path tipe :: revDs
                                  , ( name, tipe ) :: bindings
                                  )
                                  |> Names.andThen
                                      (\( revDs1, bindings1 ) ->
                                          destructHelpCollectBindings (TOpt.Index Index.second newRoot) bType b
                                              ( revDs1, bindings1 )
                                      )
                          )
      ```

      For 3‑tuple and N‑tuples, reuse the same structure as the current `destructHelp` (copy the control flow and type extraction, but call `destructHelpCollectBindings` and propagate bindings; use the same `Can.TTuple` pattern to get `aType`, `bType`, `csTypes`).

    - **Lists (`PList`), cons (`PCons`)**:

      Mirror existing `destructHelp`:

      ```elm
      Can.PList [] ->
          Names.pure ( revDs, bindings )
 
      Can.PList (hd :: tl) ->
          destructHelpCollectBindings path tipe hd
              ( revDs, bindings )
              |> Names.andThen
                  (\acc ->
                      destructHelpCollectBindings
                          path
                          tipe
                          (A.At dummyRegion (Can.PList tl))
                          acc
                  )
 
      Can.PCons hd tl ->
          destructHelpCollectBindings path tipe hd ( revDs, bindings )
              |> Names.andThen
                  (\acc ->
                      destructHelpCollectBindings path tipe tl acc
                  )
      ```

      Use the same dummy region trick as the existing helper (`A.Region (A.Position 0 0) ...`) – you can keep a small `dummyRegion` binding local to the function for clarity.

    - **Literals (`PChr`, `PStr`, `PInt`, `PBool`)**:

      These don’t bind variables:

      ```elm
      Can.PChr _ -> Names.pure ( revDs, bindings )
      Can.PStr _ _ -> Names.pure ( revDs, bindings )
      Can.PInt _ -> Names.pure ( revDs, bindings )
      Can.PBool _ _ -> Names.pure ( revDs, bindings )
      ```

    - **Constructors (`PCtor`)**:

      Mirror the logic from `destructHelp` for `PCtor` (including the special‑cases for `Normal`, `Unbox`, and `Enum`, and the two paths depending on `path` being `Root` or not), but:

        - When you generate a temp root (like `name`), *also* add `(name, tipe)` to `bindings`.
        - When you recurse on each argument pattern, use `destructHelpCollectBindings` instead of `destructHelp`.

      You can also reuse `destructCtorArg` by refactoring it to a variant that uses `destructHelpCollectBindings`. For now, it’s enough in the plan to say: copy the control flow from `destructHelp`’s `PCtor` case and change the recursive calls.

3. Once `destructHelpCollectBindings` covers all the branches that `destructHelp` currently handles, **delete the old `_ -> destructHelp ...` fallback**. This is the core fix that stops silently dropping nested bindings for tuples, lists, constructors, etc.

### 1.3. Re‑implement `destructHelp` using `destructHelpCollectBindings`

Now that `destructHelpCollectBindings` is the authoritative implementation, make `destructHelp` just a wrapper:

```elm
destructHelp : TOpt.Path -> Can.Type -> Can.Pattern -> List TOpt.Destructor -> Names.Tracker (List TOpt.Destructor)
destructHelp path tipe pattern revDs =
    destructHelpCollectBindings path tipe pattern ( revDs, [] )
        |> Names.map Tuple.first
```

- This ensures there is exactly one code path for pattern structure.
- All existing users of `destructHelp` (e.g. `destructWithType`, `destructWithKnownType`) will see the same destructors as before but we won’t risk diverging behavior.

Double‑check that nothing still calls `destructHelpCollectBindings` recursively in a way that would re‑enter the old `destructHelp` logic – we’ve now eliminated that.

---

## 2. Add helpers that expose both destructors and bindings

We already have:

- `destructCaseWithType` and `destructCase` that wrap `destructHelpCollectBindings` and return `(destructors, bindings)` for case patterns.

Now we want analogous helpers for *single patterns* with a known type, so we can use them for:

- Function arguments
- `let` destructuring

### 2.1. New helper: `destructPatternWithTypeAndBindings`

In the same module, near `destructWithType` and `destructWithKnownType`, add:

```elm
destructPatternWithTypeAndBindings
    : Can.Type
    -> Can.Pattern
    -> Names.Tracker ( A.Located Name, Can.Type, List TOpt.Destructor, List ( Name, Can.Type ) )
destructPatternWithTypeAndBindings tipe ((A.At region ptrn) as pattern) =
    case ptrn of
        Can.PVar name ->
            -- Simple variable: no destructors, one binding
            Names.pure ( A.At region name, tipe, [], [ ( name, tipe ) ] )

        Can.PAlias subPattern name ->
            -- Alias binds the alias name and any nested bindings
            destructHelpCollectBindings (TOpt.Root name) tipe subPattern ( [], [] )
                |> Names.map
                    (\( revDs, nestedBindings ) ->
                        ( A.At region name
                        , tipe
                        , TOpt.Destructor name (TOpt.Root name) tipe :: List.reverse revDs
                        , ( name, tipe ) :: nestedBindings
                        )
                    )

        _ ->
            -- Complex pattern: generate a synthetic root name, like destructWithType does today
            Names.generate
                |> Names.andThen
                    (\name ->
                        destructHelpCollectBindings (TOpt.Root name) tipe pattern ( [], [] )
                            |> Names.map
                                (\( revDs, bindings ) ->
                                    ( A.At region name
                                    , tipe
                                    , List.reverse revDs
                                    , ( name, tipe ) :: bindings
                                    )
                                )
                    )
```

Rationale:

- This is analogous to `destructWithType` today, but also returns bindings.
- The “root” binding `(name, tipe)` is included so callers can consistently put the root variable in scope along with nested ones.

---

## 3. Extend `destructArgs` / `destructTypedArgs` to also return nested bindings

Right now:

```elm
destructArgs
    : Annotations
    -> List Can.Pattern
    -> Names.Tracker ( List ( A.Located Name, Can.Type ), List TOpt.Destructor )

destructTypedArgs
    : List ( Can.Pattern, Can.Type )
    -> Names.Tracker ( List ( A.Located Name, Can.Type ), List TOpt.Destructor )
```   

They only return top‑level arg names/types plus destructors.

We want them to also return *all nested pattern bindings*.

### 3.1. Change `destructArgs` to return bindings

Change its type to:

```elm
destructArgs
    : Annotations
    -> List Can.Pattern
    -> Names.Tracker
        ( List ( A.Located Name, Can.Type )  -- function arg names + types
        , List TOpt.Destructor               -- destructors
        , List ( Name, Can.Type )            -- nested bindings (including roots)
        )
```

Implementation:

1. Change the implementation to use `destructPatternWithTypeAndBindings`:

   ```elm
   destructArgs annotations args =
       Names.traverse (destruct annotations) args
           |> Names.map
               (\results ->
                   let
                       -- change destruct to also include bindings per arg (we’ll fix destruct below)
                       ( names, types, destructorLists, bindingLists ) =
                           List.foldr
                               (\( n, t, ds, bs ) ( ns, ts, dss, bss ) ->
                                   ( n :: ns
                                   , t :: ts
                                   , ds ++ dss
                                   , bs ++ bss
                                   )
                               )
                               ( [], [], [], [] )
                               results
                   in
                   ( List.map2 Tuple.pair names types
                   , destructorLists
                   , bindingLists
                   )
               )
   ```

2. To support this, update `destruct` (typed version) to return bindings too (see step 3.3).

### 3.2. Change `destructTypedArgs` to return bindings

Similarly:

```elm
destructTypedArgs
    : List ( Can.Pattern, Can.Type )
    -> Names.Tracker
        ( List ( A.Located Name, Can.Type )
        , List TOpt.Destructor
        , List ( Name, Can.Type )
        )
```

Implementation:

```elm
destructTypedArgs typedArgs =
    Names.traverse destructTypedArg typedArgs
        |> Names.map
            (\results ->
                List.foldr
                    (\( n, ds, bs ) ( ns, dss, bss ) ->
                        ( n :: ns
                        , ds ++ dss
                        , bs ++ bss
                        )
                    )
                    ( [], [], [] )
                    results
            )
```

And update `destructTypedArg` to include bindings:

```elm
destructTypedArg
    : ( Can.Pattern, Can.Type )
    -> Names.Tracker
        ( ( A.Located Name, Can.Type )
        , List TOpt.Destructor
        , List ( Name, Can.Type )
        )
destructTypedArg ( pattern, tipe ) =
    destructPatternWithTypeAndBindings tipe pattern
        |> Names.map
            (\( locName, argType, destructors, bindings ) ->
                ( ( locName, argType ), destructors, bindings )
            )
```

### 3.3. Update `destruct` to utilize the new core and return bindings

Typed `destruct` currently returns `(locName, patternType, destructors)` based on `getPatternType` and `destructHelp`.

Change its return type and implementation to align with `destructPatternWithTypeAndBindings`:

1. Change type:

   ```elm
   destruct
       : Annotations
       -> Can.Pattern
       -> Names.Tracker
            ( A.Located Name          -- root arg name
            , Can.Type                -- root arg type
            , List TOpt.Destructor    -- destructors
            , List ( Name, Can.Type ) -- all bindings including root
            )
   ```

2. Implementation:

   ```elm
   destruct annotations pattern =
       let
           patternType : Can.Type
           patternType =
               getPatternType annotations pattern
       in
       destructPatternWithTypeAndBindings patternType pattern
   ```

   This leverages the type‑inference heuristic you already had for patterns (`getPatternType`), but now ensures nested bindings’ types are consistent with how destructuring is interpreted.

---

## 4. Update all call sites of `destructArgs` / `destructTypedArgs` to install nested bindings

Wherever you currently do:

```elm
destructArgs annotations args
    |> Names.andThen
        (\( typedArgNames, destructors ) ->
            let
                argTypes = ...
            in
            Names.withVarTypes argTypes
                (optimize ... body)
                |> ...
        )
```

you must:

- Use the new 3‑tuple return.
- Add `nestedBindings` to the type context.

Here are the main places in `Compiler/Optimize/Typed/Expression.elm` (typed optimizer) to update.

### 4.1. `Can.Lambda args body`

Current (simplified):

```elm
Can.Lambda args body ->
    destructArgs annotations args
        |> Names.andThen
            (\( typedArgNames, destructors ) ->
                let
                    argTypes =
                        List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames
                in
                Names.withVarTypes argTypes
                    (optimize cycle annotations body)
                    |> Names.map
                        (\obody -> ...)
            )
```

Change to:

```elm
Can.Lambda args body ->
    destructArgs annotations args
        |> Names.andThen
            (\( typedArgNames, destructors, bindings ) ->
                let
                    argTypes =
                        List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                    allBindings : List ( Name, Can.Type )
                    allBindings =
                        argTypes ++ bindings
                in
                Names.withVarTypes allBindings
                    (optimize cycle annotations body)
                    |> Names.map
                        (\obody -> ...)
            )
```

Note: `bindings` includes the same root arg names again; you may want to `List.filter` duplicates if that matters, but semantically it’s harmless because `withVarTypes` just folds them into the same `Dict`. (You can choose to rely on “later wins” or de‑duplicate; just be consistent.)

### 4.2. Non‑recursive `let` definitions with arguments: `optimizeDefHelp`

Look at `optimizeDefHelp` in the same file.

For the branch with arguments:

```elm
_ ->
    destructArgs annotations args
        |> Names.andThen
            (\( typedArgNames, destructors ) ->
                let
                    argTypes = ...
                in
                Names.withVarTypes argTypes
                    (optimize cycle annotations expr)
                    |> Names.andThen
                        (\oexpr -> ...)
            )
```

Change to:

```elm
_ ->
    destructArgs annotations args
        |> Names.andThen
            (\( typedArgNames, destructors, bindings ) ->
                let
                    argTypes =
                        List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                    allBindings =
                        argTypes ++ bindings
                in
                Names.withVarTypes allBindings
                    (optimize cycle annotations expr)
                    |> Names.andThen
                        (\oexpr -> ...)
            )
```

Repeat the same pattern for:

- `optimizeTypedDefHelp` (typed defs with explicit types)
- `optimizeRecDefHelp` and `optimizeTypedRecDefHelp` (recursive definitions)
- `optimizeDefForTail` and `optimizeTypedDefForTail` (tail‑call transformation of defs) where they call `destructArgs`/`destructTypedArgs`.

### 4.3. Tail‑call detection entry points

`optimizePotentialTailCall` and `optimizeTypedPotentialTailCall` also use `destructArgs`/`destructTypedArgs` to derive argument types and then call `Names.withVarTypes`.

Update them identically:

```elm
destructArgs annotations args
    |> Names.andThen
        (\( typedArgNames, destructors, bindings ) ->
            let
                argTypes = ...
                returnType = ...
                allBindings = argTypes ++ bindings
            in
            Names.withVarTypes allBindings
                (optimizeTail ...)
                |> ...
        )
```

Same for the typed variants.

---

## 5. Fix `let` destructuring to add nested bindings

Look at the `Can.LetDestruct` case in `optimize` (typed):

Currently:

```elm
Can.LetDestruct pattern expr body ->
    optimize cycle annotations expr
        |> Names.andThen
            (\oexpr ->
                let
                    exprType = TOpt.typeOf oexpr
                in
                destructWithKnownType exprType pattern
                    |> Names.andThen
                        (\( A.At nameRegion name, destructs ) ->
                            Names.withVarType name exprType
                                (optimize cycle annotations body)
                                |> Names.map
                                    (\obody ->
                                        ...
                                        TOpt.Let (TOpt.Def nameRegion name oexpr exprType)
                                            (List.foldr (wrapDestruct bodyType) obody destructs)
                                            bodyType
                                    )
                        )
            )
```

Problems:

- Only the synthetic root `name` is put into scope via `withVarType`.
- Nested pattern variables from `pattern` are not bound, leading to `Unknown variable` for things like `let (_, y) = ... in y`.

Change to use our new helper that includes bindings:

1. Add a new helper, analogous to `destructPatternWithTypeAndBindings`, but explicitly “known type” (you can reuse the same function, because here `exprType` is known):

   Either use `destructPatternWithTypeAndBindings exprType pattern` directly, or define:

   ```elm
   destructWithKnownTypeAndBindings
       : Can.Type
       -> Can.Pattern
       -> Names.Tracker
            ( A.Located Name
            , List TOpt.Destructor
            , List ( Name, Can.Type )
            )
   destructWithKnownTypeAndBindings tipe pattern =
       destructPatternWithTypeAndBindings tipe pattern
           |> Names.map
               (\( locName, _, destructors, bindings ) ->
                   ( locName, destructors, bindings )
               )
   ```

2. Update `Can.LetDestruct` implementation:

   ```elm
   Can.LetDestruct pattern expr body ->
       optimize cycle annotations expr
           |> Names.andThen
               (\oexpr ->
                   let
                       exprType : Can.Type
                       exprType =
                           TOpt.typeOf oexpr
                   in
                   destructWithKnownTypeAndBindings exprType pattern
                       |> Names.andThen
                           (\( A.At nameRegion name, destructs, bindings ) ->
                               let
                                   allBindings : List ( Name, Can.Type )
                                   allBindings =
                                       ( name, exprType ) :: bindings
                               in
                               Names.withVarTypes allBindings
                                   (optimize cycle annotations body)
                                   |> Names.map
                                       (\obody ->
                                           let
                                               bodyType : Can.Type
                                               bodyType = TOpt.typeOf obody
                                           in
                                           TOpt.Let (TOpt.Def nameRegion name oexpr exprType)
                                               (List.foldr (wrapDestruct bodyType) obody destructs)
                                               bodyType
                                       )
                           )
               )
   ```

This ensures that for `let (x, y) = expr in ...`, both `x` and `y` are in scope with appropriate types.

Note: do the same transformation in the tail‑call optimizer’s `Can.LetDestruct` branch, which currently mirrors this logic but calls `optimizeTail` on `body`.

---

## 6. `case` expressions benefit automatically once `destructHelpCollectBindings` is complete

The `Can.Case` handling in the typed optimizer already does the right thing structurally:

- It calls `destructCaseWithType`, which wraps `destructHelpCollectBindings` and returns `(destructors, patternBindings)`.
- Then:

  ```elm
  Names.withVarTypes patternBindings
      (optimize cycle annotations branch)
  ```

Since we fixed `destructHelpCollectBindings` to cover all pattern kinds, `patternBindings` will now contain `(Name, Can.Type)` entries for *nested variables* in tuple/list/constructor patterns, not just top‑level vars/records/aliases.

So no extra changes are needed for `case` besides ensuring the core helper is complete.

---

## 7. Verification & tests

After implementing the above, verify:

1. **Simple function arguments**:

    - `second (_, y) = y` compiles with typed optimization and no “Unknown variable: y” crash.
    - Variants using 3‑tuples, longer tuples, lists, pattern aliases, and constructors in arguments.

2. **`let` destructuring**:

    - `let (x, y) = expr in x + y`
    - `let Just (a, b) = maybePair in a`

   should both compile, and the generated typed IR (`TOpt.Expr`) should show `VarLocal` nodes for `x`, `y`, `a`, `b` carrying reasonable `Can.Type`s.

3. **`case` expressions**:

    - `case pair of (_, y) -> y`
    - `case list of x :: xs -> ...`  
      should also no longer crash and should have type‑annotated locals in branches.

4. **Regressions**:

    - Run the existing test suite / compiler self‑compile if you have that set up.
    - Pay particular attention to any parts of the code that call `destructArgs` or `destructTypedArgs` (search for those identifiers) and ensure all have been updated to handle the new 3‑tuple result and to feed `bindings` into `withVarTypes`.

---

## 8. Summary of concrete edits

To summarize the “where”:

- **File**: `Compiler/Optimize/Typed/Expression.elm`
    - Overhaul `destructHelpCollectBindings` to cover *all* pattern forms in lockstep with `destructHelp`.
    - Redefine `destructHelp` as a thin wrapper around `destructHelpCollectBindings`.
    - Add `destructPatternWithTypeAndBindings` and optionally `destructWithKnownTypeAndBindings`.
    - Change signatures + implementations for:
        - `destruct` (typed)
        - `destructArgs`
        - `destructTypedArgs`
        - `destructTypedArg`
    - Update call sites in:
        - `Can.Lambda` branch of `optimize`
        - `optimizeDefHelp`
        - `optimizeTypedDefHelp`
        - `optimizeRecDefHelp`
        - `optimizeTypedRecDefHelp`
        - `optimizeDefForTail`
        - `optimizeTypedDefForTail`
        - `optimizePotentialTailCall`
        - `optimizeTypedPotentialTailCall`
        - `Can.LetDestruct` in both `optimize` and `optimizeTail`

Once those are done, all pattern‑bound locals (arguments, `let`‑bound, `case`‑bound) should have type entries in `Names.Context.locals`, and `Can.VarLocal` optimization will no longer hit the `"Unknown variable"` crash for valid code.

