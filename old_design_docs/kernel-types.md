Below is a concrete implementation plan that an engineer can follow against this codebase to get **dynamic kernel function types** populated from the module’s own code, and then used in typed optimization and monomorphization.

I’ll structure it as:

1. Overall goal and invariants
2. New module: `Compiler.Optimize.Typed.KernelTypes`
3. Changes to `Compiler.Optimize.Typed.Module` (build & thread the env)
4. Changes to `Compiler.Optimize.Typed.Expression` (use the env)
5. Clean‑up / rollout notes and sanity checks

I’ll always name the module/file and the specific functions to touch, and give small explanations around each change.

---

## 1. Overall goal and invariants

Today, typed optimization fabricates a fake TVar type for kernel variables:

```elm
Can.VarKernel home name ->
    let
        placeholderType : Can.Type
        placeholderType =
            Can.TVar ("kernel_" ++ home ++ "_" ++ name)
    in
    Names.registerKernel home (TOpt.VarKernel region home name placeholderType)
```

in `Compiler.Optimize.Typed.Expression.optimize` .

Monomorphization then relies on that “type” when specializing kernel calls, but it expects a real function type (`Can.TLambda ...`) and currently just lets unification expand the single TVar arbitrarily.

**New invariant we want:**

- Every `TOpt.VarKernel` must carry a **real function type** (`Can.Type` built from `TLambda`, `TType`, `TVar`, etc.).
- These types should be obtained **from the Elm aliases** in the kernel package, like:

  ```elm
  cons : a -> List a -> List a
  cons =
    Elm.Kernel.List.cons
  ```

  so that `Elm.Kernel.List.cons` gets the same type as `cons`.

To do that without touching earlier phases, we:

- Scan the **canonical decls + annotations** in `Compiler.Optimize.Typed.Module` to build a `KernelTypeEnv` for this module.
- Thread that env into `Compiler.Optimize.Typed.Expression`.
- Use it in the `Can.VarKernel` case instead of fabricating a TVar.

---

## 2. New module: `Compiler.Optimize.Typed.KernelTypes`

**File:** `Compiler/Optimize/Typed/KernelTypes.elm` (new)

**Purpose:** Given:

- the annotations map (from type checking),
- the canonical declarations of a module,

produce a map from `(home, name)` of a kernel symbol to its canonical `Can.Type`.

We exploit the pattern:

```elm
cons : a -> List a -> List a
cons =
  Elm.Kernel.List.cons
```

which canonicalizes to either:

- `Can.Def (A.At _ "cons") [] (A.At _ (Can.VarKernel home "cons"))`, or
- `Can.TypedDef (A.At _ "cons") _ [] (A.At _ (Can.VarKernel home "cons")) resultType`.

### 2.1 Module skeleton

Create a module:

```elm
module Compiler.Optimize.Typed.KernelTypes exposing
    ( KernelTypeEnv
    , fromDecls
    , lookup
    )

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
```

### 2.2 Environment type and lookup

Use a simple dict keyed by `(home, name)`:

```elm
type alias KernelTypeEnv =
    Dict ( Name, Name ) Can.Type

lookup : Name -> Name -> KernelTypeEnv -> Maybe Can.Type
lookup home name env =
    Dict.get identity ( home, name ) env
```

Explanation:

- `home` is the short kernel module name used by `Can.VarKernel` (e.g. `"List"`, `"Utils"`), not a full `ModuleName.canonical`.
- We key by `(home, functionName)` because that is exactly what we pattern‑match on in canonical expressions.

### 2.3 Derive env from decls

We need the same annotations type as `Typed.Module` (`Dict String Name Can.Annotation` ). You can either:

- redefine a local alias, or
- just accept the dict directly. I’ll show a local alias for clarity:

```elm
type alias Annotations =
    Dict String Name Can.Annotation
```

Now implement `fromDecls`:

```elm
fromDecls : Annotations -> Can.Decls -> KernelTypeEnv
fromDecls annotations decls =
    let
        annotationToType : Name -> Can.Type
        annotationToType defName =
            case Dict.get identity defName annotations of
                Just (Can.Forall _ tipe) ->
                    tipe

                Nothing ->
                    -- This should not happen in well-typed code, but keep a
                    -- placeholder rather than crash in the first version.
                    Can.TVar ("missing_annot_" ++ defName)

        stepDef : Can.Def -> KernelTypeEnv -> KernelTypeEnv
        stepDef def env =
            case def of
                -- Untyped def, 0 args, body is exactly a VarKernel
                Can.Def (A.At _ name) [] (A.At _ (Can.VarKernel home kernelName)) ->
                    let
                        tipe : Can.Type
                        tipe =
                            annotationToType name
                    in
                    Dict.insert identity ( home, kernelName ) tipe env

                -- Typed def, 0 args, body is exactly a VarKernel
                Can.TypedDef (A.At _ name) _ [] (A.At _ (Can.VarKernel home kernelName)) resultType ->
                    -- For typed defs, resultType is the canonical function type
                    Dict.insert identity ( home, kernelName ) resultType env

                _ ->
                    env

        stepDecls : Can.Decls -> KernelTypeEnv -> KernelTypeEnv
        stepDecls ds env =
            case ds of
                Can.Declare def rest ->
                    stepDecls rest (stepDef def env)

                Can.DeclareRec d ds rest ->
                    -- Recursive groups: still just scan individual defs
                    let
                        env1 =
                            List.foldl stepDef env (d :: ds)
                    in
                    stepDecls rest env1

                Can.SaveTheEnvironment ->
                    env
    in
    stepDecls decls Dict.empty
```

Explanation:

- We only handle **zero‑argument** top‑level defs where the body is *exactly* a `VarKernel`.
- This matches the typical kernel aliases: `foo = Elm.Kernel.X.foo`.
- `annotationToType` unwraps `Can.Forall` into the underlying `Can.Type`, like `lookupAnnotationType` in `Typed.Module` does for other use sites .

You can tighten this later (e.g. crash on `Nothing` in `annotationToType`) once you’re confident every used alias has an annotation.

---

## 3. Changes to `Compiler.Optimize.Typed.Module`

**File:** `Compiler/Optimize/Typed/Module.elm`

This module is the entry point for typed optimization:

```elm
optimize : Annotations -> Can.Module -> MResult i (List W.Warning) TOpt.LocalGraph
optimize annotations (Can.Module canData) =
    TOpt.LocalGraph { main = Nothing, nodes = Dict.empty, fields = Dict.empty, annotations = annotations }
        |> addAliases canData.name annotations canData.aliases
        |> addUnions canData.name annotations canData.unions
        |> addEffects canData.name annotations canData.effects
        |> addDecls canData.name annotations canData.decls
```

We need to:

1. Compute `KernelTypeEnv` once here.
2. Thread it into `addDecls` and then down to every call to `Expr.optimize` / `Expr.optimizePotentialTailCall`.

### 3.1 Import the new module

At the top, add:

```elm
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
```

### 3.2 Compute env in `optimize`

Update the body of `optimize` to build a `kernelEnv`:

```elm
optimize : Annotations -> Can.Module -> MResult i (List W.Warning) TOpt.LocalGraph
optimize annotations (Can.Module canData) =
    let
        kernelEnv : KernelTypes.KernelTypeEnv
        kernelEnv =
            KernelTypes.fromDecls annotations canData.decls
    in
    TOpt.LocalGraph { main = Nothing, nodes = Dict.empty, fields = Dict.empty, annotations = annotations }
        |> addAliases canData.name annotations canData.aliases
        |> addUnions canData.name annotations canData.unions
        |> addEffects canData.name annotations canData.effects
        |> addDecls canData.name annotations kernelEnv canData.decls
```

Only `addDecls`’s call site changes here.

### 3.3 Thread env through `addDecls` and helpers

**Change 1: signature of `addDecls`**

Current:

```elm
addDecls : IO.Canonical -> Annotations -> Can.Decls -> TOpt.LocalGraph -> MResult i (List W.Warning) TOpt.LocalGraph
addDecls home annotations decls graph =
    ReportingResult.loop (addDeclsHelp home annotations) ( decls, graph )
```

New:

```elm
addDecls :
    IO.Canonical
    -> Annotations
    -> KernelTypes.KernelTypeEnv
    -> Can.Decls
    -> TOpt.LocalGraph
    -> MResult i (List W.Warning) TOpt.LocalGraph
addDecls home annotations kernelEnv decls graph =
    ReportingResult.loop (addDeclsHelp home annotations kernelEnv) ( decls, graph )
```

**Change 2: signature of `addDeclsHelp`**

Current:

```elm
addDeclsHelp :
    IO.Canonical
    -> Annotations
    -> ( Can.Decls, TOpt.LocalGraph )
    -> MResult i (List W.Warning) (ReportingResult.Step ( Can.Decls, TOpt.LocalGraph ) TOpt.LocalGraph)
addDeclsHelp home annotations ( decls, graph ) =
    case decls of
        Can.Declare def subDecls ->
            addDef home annotations def graph
                |> ReportingResult.map (ReportingResult.Loop << Tuple.pair subDecls)

        Can.DeclareRec d ds subDecls ->
            ...
            ReportingResult.ok (ReportingResult.Loop ( subDecls, addRecDefs home annotations defs graph ))
```

New:

```elm
addDeclsHelp :
    IO.Canonical
    -> Annotations
    -> KernelTypes.KernelTypeEnv
    -> ( Can.Decls, TOpt.LocalGraph )
    -> MResult i (List W.Warning) (ReportingResult.Step ( Can.Decls, TOpt.LocalGraph ) TOpt.LocalGraph)
addDeclsHelp home annotations kernelEnv ( decls, graph ) =
    case decls of
        Can.Declare def subDecls ->
            addDef home annotations kernelEnv def graph
                |> ReportingResult.map (ReportingResult.Loop << Tuple.pair subDecls)

        Can.DeclareRec d ds subDecls ->
            let
                defs =
                    d :: ds
            in
            case findMain defs of
                Nothing ->
                    ReportingResult.ok
                        (ReportingResult.Loop
                            ( subDecls
                            , addRecDefs home annotations kernelEnv defs graph
                            )
                        )

                Just region ->
                    E.BadCycle region (defToName d) (List.map defToName ds) |> ReportingResult.throw

        Can.SaveTheEnvironment ->
            ReportingResult.ok (ReportingResult.Done graph)
```

Explanation:

- `addDef` and `addRecDefs` now also receive `kernelEnv`, so they can pass it to expression optimization.

### 3.4 Update `addDef` / `addDefHelp` to accept env

Current `addDef` :

```elm
addDef : IO.Canonical -> Annotations -> Can.Def -> TOpt.LocalGraph -> MResult i (List W.Warning) TOpt.LocalGraph
addDef home annotations def graph =
    case def of
        Can.Def (A.At region name) args body ->
            let
                (Can.Forall _ tipe) =
                    Utils.find identity name annotations
            in
            ReportingResult.warn (W.MissingTypeAnnotation region name tipe)
                |> ReportingResult.andThen (\_ -> addDefHelp region annotations home name args body Nothing graph)

        Can.TypedDef (A.At region name) _ typedArgs body resultType ->
            addDefHelp region annotations home name (List.map Tuple.first typedArgs) body (Just ( typedArgs, resultType )) graph
```

New:

```elm
addDef :
    IO.Canonical
    -> Annotations
    -> KernelTypes.KernelTypeEnv
    -> Can.Def
    -> TOpt.LocalGraph
    -> MResult i (List W.Warning) TOpt.LocalGraph
addDef home annotations kernelEnv def graph =
    case def of
        Can.Def (A.At region name) args body ->
            let
                (Can.Forall _ tipe) =
                    Utils.find identity name annotations
            in
            ReportingResult.warn (W.MissingTypeAnnotation region name tipe)
                |> ReportingResult.andThen
                    (\_ ->
                        addDefHelp region annotations kernelEnv home name args body Nothing graph
                    )

        Can.TypedDef (A.At region name) _ typedArgs body resultType ->
            addDefHelp region annotations kernelEnv home name (List.map Tuple.first typedArgs) body (Just ( typedArgs, resultType )) graph
```

Update `addDefHelp` signature and calls to `addDefNode`:

Current head and usage :

```elm
addDefHelp :
    A.Region
    -> Annotations
    -> IO.Canonical
    -> Name.Name
    -> List Can.Pattern
    -> Can.Expr
    -> Maybe ( List ( Can.Pattern, Can.Type ), Can.Type )
    -> TOpt.LocalGraph
    -> MResult i w TOpt.LocalGraph
addDefHelp region annotations home name args body maybeTypedArgs ((TOpt.LocalGraph graphData) as graph) =
    if name /= Name.main_ then
        ReportingResult.ok (addDefNode home annotations region name args body maybeTypedArgs EverySet.empty graph)
    else
        ...
        addMain ( deps, localFields, main ) =
            TOpt.LocalGraph { graphData | main = Just main, fields = ... }
                |> addDefNode home annotations region name args body maybeTypedArgs deps
```

New:

```elm
addDefHelp :
    A.Region
    -> Annotations
    -> KernelTypes.KernelTypeEnv
    -> IO.Canonical
    -> Name.Name
    -> List Can.Pattern
    -> Can.Expr
    -> Maybe ( List ( Can.Pattern, Can.Type ), Can.Type )
    -> TOpt.LocalGraph
    -> MResult i w TOpt.LocalGraph
addDefHelp region annotations kernelEnv home name args body maybeTypedArgs ((TOpt.LocalGraph graphData) as graph) =
    if name /= Name.main_ then
        ReportingResult.ok (addDefNode home annotations kernelEnv region name args body maybeTypedArgs EverySet.empty graph)

    else
        let
            (Can.Forall _ tipe) =
                Utils.find identity name annotations

            addMain : ( EverySet (List String) TOpt.Global, Dict String Name.Name Int, TOpt.Main ) -> TOpt.LocalGraph
            addMain ( deps, localFields, main ) =
                TOpt.LocalGraph
                    { graphData
                        | main = Just main
                        , fields = Utils.mapUnionWith identity compare (+) localFields graphData.fields
                    }
                    |> addDefNode home annotations kernelEnv region name args body maybeTypedArgs deps
        in
        -- same Type.deepDealias logic as before, unchanged
        ...
```

### 3.5 Pass env into `Expr.optimize` / `Expr.optimizePotentialTailCall` inside `addDefNode`

Current `addDefNode` (relevant part) :

```elm
addDefNode home annotations region name args body maybeTypedArgs mainDeps graph =
    let
        defType : Can.Type
        defType =
            lookupAnnotationType name annotations

        ( deps, localFields, def ) =
            Names.run annotations <|
                case ( args, maybeTypedArgs ) of
                    ( [], _ ) ->
                        Expr.optimize EverySet.empty annotations body
                            |> Names.map
                                (\oexpr ->
                                    TOpt.TrackedFunction [] oexpr defType
                                )

                    ( _, Just ( _, resultType ) ) ->
                        Expr.destructArgs annotations args
                            |> Names.andThen
                                (\( typedArgNames, destructors ) ->
                                    ...
                                    Names.withVarTypes argBindings
                                        (Expr.optimize EverySet.empty annotations body)
                                        |> Names.map
                                            (\obody -> ...)
                                )

                    ( _, Nothing ) ->
                        Expr.destructArgs annotations args
                            |> Names.andThen
                                (\( typedArgNames, destructors ) ->
                                    ...
                                    Names.withVarTypes argBindings
                                        (Expr.optimize EverySet.empty annotations body)
                                        |> Names.map
                                            (\obody -> ...)
                                )
    in
    addToGraph (TOpt.Global home name) (TOpt.TrackedDefine region def (EverySet.union deps mainDeps) defType) localFields graph
```

Change the signature (added `KernelTypes.KernelTypeEnv` earlier) and then:

```elm
addDefNode :
    IO.Canonical
    -> Annotations
    -> KernelTypes.KernelTypeEnv
    -> A.Region
    -> Name.Name
    -> List Can.Pattern
    -> Can.Expr
    -> Maybe ( List ( Can.Pattern, Can.Type ), Can.Type )
    -> EverySet (List String) TOpt.Global
    -> TOpt.LocalGraph
    -> TOpt.LocalGraph
addDefNode home annotations kernelEnv region name args body maybeTypedArgs mainDeps graph =
    let
        defType : Can.Type
        defType =
            lookupAnnotationType name annotations

        ( deps, localFields, def ) =
            Names.run annotations <|
                case ( args, maybeTypedArgs ) of
                    ( [], _ ) ->
                        Expr.optimize kernelEnv EverySet.empty annotations body
                            |> Names.map
                                (\oexpr ->
                                    TOpt.TrackedFunction [] oexpr defType
                                )

                    ( _, Just ( _, resultType ) ) ->
                        Expr.destructArgs annotations args
                            |> Names.andThen
                                (\( typedArgNames, destructors ) ->
                                    let
                                        argBindings =
                                            List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames
                                    in
                                    Names.withVarTypes argBindings
                                        (Expr.optimize kernelEnv EverySet.empty annotations body)
                                        |> Names.map
                                            (\obody -> ...)
                                )

                    ( _, Nothing ) ->
                        Expr.destructArgs annotations args
                            |> Names.andThen
                                (\( typedArgNames, destructors ) ->
                                    let
                                        argBindings = ...
                                        returnType = ...
                                    in
                                    Names.withVarTypes argBindings
                                        (Expr.optimize kernelEnv EverySet.empty annotations body)
                                        |> Names.map
                                            (\obody -> ...)
                                )
    in
    ...
```

Explanation:

- We **only** changed the calls to `Expr.optimize` to pass `kernelEnv` as first argument.
- Everything else remains identical.

### 3.6 Thread env into recursive defs (`addRecDefs` and helpers)

At the bottom of `Typed.Module` you have `addRecDefs`, `addRecDef`, etc.  They build mutually recursive cycles and call into `Expr.optimizePotentialTailCallDef` / `Expr.optimize`.

You’ll need to:

1. Extend `addRecDefs` signature to include `KernelTypeEnv`, consistently with `addDecls`:

   ```elm
   addRecDefs :
       IO.Canonical
       -> Annotations
       -> KernelTypes.KernelTypeEnv
       -> List Can.Def
       -> TOpt.LocalGraph
       -> TOpt.LocalGraph
   ```

2. Where `Names.run` is used with `addRecDef`:

   ```elm
   ( deps, localFields, State { values, functions } ) =
       Names.run annotations <|
           List.foldl (\def -> Names.andThen (\state -> addRecDef cycle annotations state def))
               (Names.pure (State { values = [], functions = [] }))
               defs
   ```

   update `addRecDef` to accept `kernelEnv` and pass it through:

   ```elm
   addRecDef :
       EverySet String Name.Name
       -> Annotations
       -> KernelTypes.KernelTypeEnv
       -> State
       -> Can.Def
       -> Names.Tracker State
   ```

   and then in the fold:

   ```elm
   List.foldl
       (\def -> Names.andThen (\state -> addRecDef cycle annotations kernelEnv state def))
       ...
   ```

3. Inside `addRecDef`, wherever you currently call:

   - `Expr.optimizePotentialTailCallDef cycle annotations def`
   - or `Expr.optimize cycle annotations ...`

   update those calls to:

   - `Expr.optimizePotentialTailCallDef kernelEnv cycle annotations def`
   - `Expr.optimize kernelEnv cycle annotations ...`

You can find all call sites with a simple search for `Expr.optimize` and `Expr.optimizePotentialTailCallDef` in `Compiler.Optimize.Typed.Module` and consistently add `kernelEnv` as the new first argument.

---

## 4. Changes to `Compiler.Optimize.Typed.Expression`

**File:** `Compiler/Optimize/Typed/Expression.elm`

This is the core of typed optimization. It needs two kinds of changes:

1. Its exported entry points need to accept a `KernelTypeEnv`.
2. Inside `optimize`, the `Can.VarKernel` case must look up the kernel type instead of fabricating a TVar.
3. All internal recursive calls to `optimize` / `optimizeTail` / `optimizePotentialTailCall` must be updated to thread the env.

### 4.1 Import the new module

At the top:

```elm
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
```

### 4.2 Change the `optimize` signature (and call sites)

Current signature and comment :

```elm
optimize : Cycle -> Annotations -> Can.Expr -> Names.Tracker TOpt.Expr
```

New:

```elm
optimize :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> Can.Expr
    -> Names.Tracker TOpt.Expr
```

Update the definition header accordingly:

```elm
optimize kernelEnv cycle annotations (A.At region expression) =
    case expression of
        ...
```

**Important:** Every internal call that previously did `optimize cycle annotations` must now do `optimize kernelEnv cycle annotations`. For example:

- `Can.List entries` case currently:

  ```elm
  Names.traverse (optimize cycle annotations) entries
  ```

  becomes:

  ```elm
  Names.traverse (optimize kernelEnv cycle annotations) entries
  ```

- `Can.Call func args` case:

  ```elm
  optimize cycle annotations func
      |> Names.andThen
          (\optFunc ->
              Names.traverse (optimize cycle annotations) args
                  |> Names.map
                      (\optArgs -> ...)
          )
  ```

  becomes:

  ```elm
  optimize kernelEnv cycle annotations func
      |> Names.andThen
          (\optFunc ->
              Names.traverse (optimize kernelEnv cycle annotations) args
                  |> Names.map
                      (\optArgs -> ...)
          )
  ```

Do a search for `optimize cycle annotations` in this file and replace with `optimize kernelEnv cycle annotations` consistently.

### 4.3 Use kernelEnv in `Can.VarKernel` instead of fake TVar

Replace the `Can.VarKernel` arm:

Current :

```elm
Can.VarKernel home name ->
    -- Kernel vars don't have type annotations in the canonical AST.
    -- Use a type variable as a placeholder - the actual type will be
    -- determined when this is used in context (e.g., in a call).
    let
        placeholderType : Can.Type
        placeholderType =
            Can.TVar ("kernel_" ++ home ++ "_" ++ name)
    in
    Names.registerKernel home (TOpt.VarKernel region home name placeholderType)
```

New:

```elm
Can.VarKernel home name ->
    let
        tipe : Can.Type
        tipe =
            case KernelTypes.lookup home name kernelEnv of
                Just t ->
                    t

                Nothing ->
                    -- During rollout you can keep a fallback instead of crashing:
                    -- Can.TVar ("kernel_" ++ home ++ "_" ++ name)
                    crash ("Missing kernel type for " ++ home ++ "." ++ name)
    in
    Names.registerKernel home (TOpt.VarKernel region home name tipe)
```

Explanation:

- `home` and `name` here are the same `Name` values we recorded in `KernelTypes.fromDecls`, so `lookup` will succeed when the module contains something like `foo = Elm.Kernel.home.name` with a type.
- Once this is in place, every `TOpt.VarKernel` in the typed IR carries a real `Can.Type` function type, which `Monomorphize` already knows how to use via `unifyFuncCall` .

### 4.4 Thread env into tail‑call optimization helpers

Further down in this file, functions related to tail‑call detection and recursive defs call `optimize` and `optimizeTail`. Examples:

- `optimizePotentialTailCall` and `optimizeTail`
- `optimizeDefAndBody`, `optimizeLetRecDefs`, `optimizeRecDefHelp`, `optimizeTypedRecDefHelp`

You’ll need to:

1. Change their type signatures by adding `KernelTypeEnv` as the first argument.
2. Update their bodies to pass `kernelEnv` when they call `optimize` and `optimizeTail`.

Concretely:

**(a) `optimizePotentialTailCall`**

Current:

```elm
optimizePotentialTailCall :
    Cycle -> Annotations -> A.Region -> Name -> List Can.Pattern -> Can.Expr -> Names.Tracker TOpt.Def
```

New:

```elm
optimizePotentialTailCall :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> Can.Expr
    -> Names.Tracker TOpt.Def
```

And in its body:

```elm
Names.withVarTypes argTypes
    (optimizeTail cycle annotations name typedArgNames returnType expr)
```

becomes:

```elm
Names.withVarTypes argTypes
    (optimizeTail kernelEnv cycle annotations name typedArgNames returnType expr)
```

**(b) `optimizePotentialTailCallDef`**

Current:

```elm
optimizePotentialTailCallDef : Cycle -> Annotations -> Can.Def -> Names.Tracker TOpt.Def
optimizePotentialTailCallDef cycle annotations def =
    case def of
        Can.Def ... -> optimizePotentialTailCall cycle annotations ...
        ...
```

New:

```elm
optimizePotentialTailCallDef :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> Can.Def
    -> Names.Tracker TOpt.Def
optimizePotentialTailCallDef kernelEnv cycle annotations def =
    case def of
        Can.Def ... ->
            optimizePotentialTailCall kernelEnv cycle annotations ...

        Can.TypedDef ... ->
            optimizeTypedPotentialTailCall kernelEnv cycle annotations ...
```

**(c) `optimizeTypedPotentialTailCall`**

Add `kernelEnv` similarly and pass it through to `optimizeTail`.

**(d) `optimizeTail`**

Current:

```elm
optimizeTail :
    Cycle -> Annotations -> Name -> List ( A.Located Name, Can.Type ) -> Can.Type -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeTail cycle annotations rootName typedArgNames returnType ((A.At region expression) as locExpr) =
    case expression of
        Can.Call func args ->
            Names.traverse (optimize cycle annotations) args
                |> Names.andThen
                    (\oargs -> ...)
```

New:

```elm
optimizeTail :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> Can.Type
    -> Can.Expr
    -> Names.Tracker TOpt.Expr
optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType ((A.At region expression) as locExpr) =
    case expression of
        Can.Call func args ->
            Names.traverse (optimize kernelEnv cycle annotations) args
                |> Names.andThen
                    (\oargs -> ...)
```

And later in this function, any `optimize cycle annotations` calls must become `optimize kernelEnv cycle annotations`.

**(e) `optimizeDefAndBody`, `optimizeLetRecDefs`, `optimizeRecDefHelp`, `optimizeTypedRecDefHelp`**

All of these currently have signatures that start with `Cycle -> Annotations -> ...` and internally call `optimize` / `optimizeTail` without env. You need to:

- Add `KernelTypeEnv` as first parameter.
- Update calls to:

   - `optimize kernelEnv cycle annotations`
   - `optimizeTail kernelEnv cycle annotations ...`
   - `optimizePotentialTailCallDef kernelEnv cycle annotations`

For example, from :

```elm
optimizeLetRecDefs cycle annotations defs body =
    ...
    Names.withVarTypes defBindings
        (List.foldl
            (\def bod ->
                Names.andThen (optimizeRecDefToLet cycle annotations def) bod
            )
            (optimize cycle annotations body)
            defs
        )
```

becomes:

```elm
optimizeLetRecDefs kernelEnv cycle annotations defs body =
    ...
    Names.withVarTypes defBindings
        (List.foldl
            (\def bod ->
                Names.andThen (optimizeRecDefToLet kernelEnv cycle annotations def) bod
            )
            (optimize kernelEnv cycle annotations body)
            defs
        )
```

Do this systematically for all internal helpers in this file.

---

## 5. Rollout & sanity checks

**5.1 Transitional behavior**

- Initially, you might choose to keep the `Nothing` case in `KernelTypes.lookup` → `Can.VarKernel` fallback as a fake TVar (with a log/crash later) to avoid breaking code until you’ve audited all kernel aliases.
- Once confident, change the fallback to `crash` so missing kernel types are caught early.

**5.2 No changes to earlier phases**

- Canonicalization (`Compiler.Canonicalize.*`) and type checking (`Compiler.Type.*`) remain unchanged.
- `Can.VarKernel` is still untyped in canonical AST; we only add typing information in the typed optimization phase, which already receives the `annotations` map from type checking via `Compile.compileTyped` .

**5.3 No changes to monomorphization**

- `Compiler.Optimize.Mono` (Monomorphize) already expects `TOpt.VarKernel` to carry a `Can.Type` and unifies that with argument/result mono types via `unifyFuncCall` .
- Once kernel vars reference real `TLambda`‑based function types, specialization of kernel calls will behave exactly like specialization of polymorphic globals.

**5.4 Quick checks**

After implementing:

1. Build and run the existing test suite / example programs that use kernel List functions, String, Utils, etc.
2. Optionally add a debug helper:

   - After building `kernelEnv` in `Typed.Module.optimize`, print or log its keys in debug builds to ensure the expected `(home, name)` pairs are present.
3. For a known alias like `cons` in `List`, inspect the generated typed graph (e.g., via your existing `.guidato` dump) to confirm:

   - References to `TOpt.VarKernel _ "List" "cons" funcType` now show `funcType` as a chain of `Can.TLambda` nodes with the right argument/result `Can.Type`s.

---

If you follow these steps in order—add `KernelTypes`, thread the env through `Typed.Module`, then update `Typed.Expression` and its helpers—you’ll end up with dynamically populated kernel function types derived from the module’s own code, without touching canonicalization or type inference, and with monomorphization automatically getting the richer type information it needs.

