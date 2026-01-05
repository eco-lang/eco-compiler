Here is a concrete, engineer‑oriented design for going from `TypedCanonical` to `TypedOptimized`, with the extra requirements you listed.

I’ll structure it by module, and for each change I’ll say:

- what the API / signature should be,
- what code to write or move,
- and what the intent is.

I’ll assume “typed optimizer code under `Compiler.Optimize.Typed`” (matching the existing stub module ).

---

## 0. Goals & invariants

We want a typed optimizer that:

- Takes a **`TypedCanonical.Module`** as input (not just `Can.Module`).
- Produces a **`TypedOptimized.LocalGraph`** with types on every expression and node.
- Reuses the same *control flow* as the erased optimizer (`Compiler.Optimize.Erased.Module` + `.Expression`) .
- Uses **`TypedCanonical`’s expression types** wherever possible (all `TCan.Expr` have a final `Can.Type` from the solver).
- Has:
    - a typed `Names` context that tracks `(Name, Can.Type)`,
    - real kernel function types from module aliases,
    - local def types inferred from RHS/patterns (never from top‑level annotations),
    - correctly typed graph nodes for unions, aliases, effects, ports, etc.

---

## 1. Pipeline integration (`Compiler.Compile`)

### 1.1 Use `typeCheckTyped` in the typed pipeline

You already have `typeCheckTyped` that returns both `annotations` and `typedCanonical` :

```elm
typeCheckTyped :
    Src.Module
    -> Can.Module
    -> Result
        E.Error
        { annotations : Dict String Name Can.Annotation
        , typedCanonical : TCan.Module
        }
```

Update `compileTyped` to use this instead of plain `typeCheck`:

```elm
compileTyped :
    Pkg.Name
    -> Dict String ModuleName.Raw I.Interface
    -> Src.Module
    -> Task Never (Result E.Error TypedArtifacts)
compileTyped pkg ifaces modul =
    Task.succeed
        (canonicalize pkg ifaces modul
            |> (\canonicalResult ->
                    case canonicalResult of
                        Ok canonical ->
                            typeCheckTyped modul canonical
                                |> Result.andThen
                                    (\{ annotations, typedCanonical } ->
                                        nitpick canonical
                                            |> Result.andThen
                                                (\() ->
                                                    optimize modul annotations canonical
                                                        |> Result.andThen
                                                            (\objects ->
                                                                typedOptimizeFromTyped modul annotations typedCanonical
                                                                    |> Result.map
                                                                        (\typedObjects ->
                                                                            TypedArtifacts
                                                                                { canonical = canonical
                                                                                , annotations = annotations
                                                                                , objects = objects
                                                                                , typedObjects = typedObjects
                                                                                }
                                                                        )
                                                            )
                                                )
                                    )

                        Err err ->
                            Err err
               )
        )
```

Intent:

- Run type checking once.
- Use the same `annotations` map for erased and typed optimizers.
- Feed `TCan.Module` into the typed optimizer.

### 1.2 New helper `typedOptimizeFromTyped`

Add a new internal function in `Compile.elm`:

```elm
typedOptimizeFromTyped :
    Src.Module
    -> Dict String Name.Name Can.Annotation
    -> TCan.Module
    -> Result E.Error TOpt.LocalGraph
typedOptimizeFromTyped modul annotations tcanModule =
    case Tuple.second (ReportingResult.run (TypedOptimize.optimize annotations tcanModule)) of
        Ok localGraph ->
            Ok localGraph

        Err errors ->
            Err (E.BadMains (Localizer.fromModule modul) errors)
```

At the same time, you can:

- Either keep the existing `typedOptimize` (that takes `Can.Module`) as a thin wrapper: build `TCan.Module` there,
- Or remove it if nothing else uses it.

---

## 2. Typed optimizer entry point (`Compiler.Optimize.Typed.Module`)

Currently this file has a stub `optimize : Annotations -> Can.Module -> ...` that crashes .

### 2.1 Change the signature to take `TCan.Module`

Update the module header:

```elm
module Compiler.Optimize.Typed.Module exposing
    ( Annotations, MResult
    , optimize
    )
```

Add imports:

```elm
import Compiler.AST.TypedCanonical as TCan
import Compiler.Optimize.Typed.Expression as Expr
import Compiler.Optimize.Typed.Names as Names
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
```

Change `optimize` to:

```elm
type alias Annotations =
    Dict String Name.Name Can.Annotation

optimize : Annotations -> TCan.Module -> MResult i (List W.Warning) TOpt.LocalGraph
optimize annotations (TCan.Module tData) =
    let
        -- Build kernel function type environment once from decls
        kernelEnv : KernelTypes.KernelTypeEnv
        kernelEnv =
            KernelTypes.fromDecls annotations tData.decls
    in
    TOpt.LocalGraph
        { main = Nothing
        , nodes = Dict.empty
        , fields = Dict.empty
        , annotations = annotations
        }
        |> addAliases tData.name annotations tData.aliases
        |> addUnions  tData.name annotations tData.unions
        |> addEffects tData.name annotations tData.effects
        |> addDecls   tData.name annotations kernelEnv tData.decls
```

Intent:

- Mirror the erased optimizer flow `addAliases → addUnions → addEffects → addDecls` .
- But operate on `TCan.Module` and build a `TOpt.LocalGraph` whose `LocalGraphData` retains `annotations`.

### 2.2 Implement typed `addAliases`, `addUnions`, `addEffects`, `addDecls`

Use `Compiler.Optimize.Erased.Module` as a template. Key differences:

- Use `TOpt.LocalGraph` and `TOpt.Node`, not `Opt.LocalGraph` and `Opt.Node`.
- For nodes that represent functions/ctors/ports, **supply the canonical type**.

**Aliases** (record alias constructors):

```elm
addAliases :
    IO.Canonical
    -> Annotations
    -> Dict String Name.Name Can.Alias
    -> TOpt.LocalGraph
    -> TOpt.LocalGraph
addAliases home annotations aliases graph =
    Dict.foldr compare (addAlias home annotations) graph aliases

addAlias :
    IO.Canonical
    -> Annotations
    -> Name.Name
    -> Can.Alias
    -> TOpt.LocalGraph
    -> TOpt.LocalGraph
addAlias home annotations name (Can.Alias _ tipe) ((TOpt.LocalGraph data) as graph) =
    case tipe of
        Can.TRecord fields Nothing ->
            let
                -- Function that builds records from fields, typed
                argTypes : List ( Name, Can.Type )
                argTypes =
                    Can.fieldsToList fields
                        |> List.map (\(fieldName, fieldType) -> ( fieldName, fieldType ))

                funcType : Can.Type
                funcType =
                    -- a -> b -> { a : a, b : b } etc.
                    List.foldr
                        (\(_, tArg) acc -> Can.TLambda tArg acc)
                        tipe
                        argTypes

                function : TOpt.Expr
                function =
                    let
                        argsWithTypes =
                            List.map (\(n, t) -> ( A.At A.zero n, t )) argTypes
                    in
                    -- Body: record literal with VarLocal fields
                    let
                        bodyRecord =
                            fields
                                |> Dict.map (\field _ -> TOpt.VarLocal field (Dict.findWithDefault identity field fields |> Tuple.second))
                                |> TOpt.Record
                    in
                    TOpt.TrackedFunction argsWithTypes bodyRecord funcType

                node : TOpt.Node
                node =
                    TOpt.Define function EverySet.empty funcType
            in
            TOpt.LocalGraph
                { data
                    | nodes =
                        Dict.insert TOpt.toComparableGlobal (TOpt.Global home name) node data.nodes
                    , fields =
                        Dict.foldr compare addRecordCtorField data.fields fields
                }

        _ ->
            graph
```

Use erased `addAlias` as a shape reference (same record logic) but emit a typed function and typed node.

**Unions / ctors**:

Mirror `addUnions/addUnion/addCtorNode` from erased `Module` , but each `TOpt.Ctor`/`Enum` node takes a `Can.Type`:

- For each `Can.Ctor`, compute its function type from the union’s type variables and argument types.
- Store that in `TOpt.Ctor index arity ctorType`.

Monomorphization later will use this `ctorType` to build layouts.

**Effects / ports**:

Mirror `addEffects` from erased `Module` , but:

- Use `TOpt.Manager` / `TOpt.PortIncoming` / `TOpt.PortOutgoing` nodes instead of `Opt.Manager` / `Opt.PortIncoming` / `Opt.PortOutgoing` (check `TOpt.Node` constructors).
- For ports, attach the canonical port type from `annotations` when constructing `TOpt.PortIncoming`/`PortOutgoing`. Their encoders/decoders are `TOpt.Expr` with types (see below).

**Decls**:

Implement:

```elm
addDecls :
    IO.Canonical
    -> Annotations
    -> KernelTypes.KernelTypeEnv
    -> TCan.Decls
    -> TOpt.LocalGraph
    -> TOpt.LocalGraph
```

Shape it like erased `addDecls`:

- Walk `TCan.Decls` (`Declare`, `DeclareRec`, `SaveTheEnvironment`) .
- For each def or recursive group, run a `Names.run` tracker over `Typed.Expression.optimize`/`optimizePotentialTailCallDef` to get:
    - optimized typed `TOpt.Def`/`TOpt.Expr`,
    - dependency set (`EverySet` of `TOpt.Global`),
    - and any field usage info.
- Insert appropriate `TOpt.Node`s into `LocalGraph`.

---

## 3. Typed Names environment (`Compiler.Optimize.Typed.Names`)

This is parallel to `Compiler.Optimize.Erased.Names` (used by erased `Expression.optimize`) , but carries types in the local context.

### 3.1 API shape

Create `Compiler/Optimize/Typed/Names.elm`:

```elm
module Compiler.Optimize.Typed.Names exposing
    ( Tracker
    , pure, map, andThen
    , withVarType, withVarTypes
    , registerGlobal, registerKernel, registerCtor, registerDebug
    , run
    )

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
```

Core ideas:

- `Tracker a` is a monad that carries:
    - dependencies (`EverySet` of `TOpt.Global`),
    - field access map,
    - and a locals environment: `Dict Name Can.Type`.

- `withVarType : Name -> Can.Type -> Tracker a -> Tracker a`:
    - temporarily extends the locals map with a single binding.

- `withVarTypes : List ( Name, Can.Type ) -> Tracker a -> Tracker a`:
    - extends with many bindings.

- `registerGlobal`, `registerKernel`, `registerCtor`, `registerDebug`:
    - record dependencies and return the corresponding `TOpt.Expr` constructor (with type supplied by caller).

Intent:

- Exactly the same dependency/field‑count behavior as erased `Names`,
- but with a typed locals environment used by `Expression.optimize` for `Can.VarLocal` etc.

---

## 4. Kernel types (`Compiler.Optimize.Typed.KernelTypes`)

You already have a design for this module: `KernelTypeEnv` + `fromDecls` + `lookup`.

### 4.1 Purpose

`KernelTypeEnv` maps `(home, name)` (for kernel functions like `Elm.Kernel.List.cons`) to a **real `Can.Type`** representing the function type, derived from top‑level aliases like:

```elm
cons : a -> List a -> List a
cons = Elm.Kernel.List.cons
```

Given `annotations` and `TCan.Decls`, `fromDecls` should:

- Find zero‑arg defs whose bodies are exactly `VarKernel` uses, and
- Use their annotations (top‑level scheme) to populate the map.

This is unchanged by using `TypedCanonical`, since its `Decls` still represent the same top‑level structure.

### 4.2 Use in `Expression.optimize`

In `Typed.Expression.optimize` (below), when you see `Can.VarKernel home name`, do:

- `KernelTypes.lookup (home, name) kernelEnv` to get `Can.Type` (crash with a clear message if missing),
- and construct `TOpt.VarKernel region home name kernelType`.

---

## 5. Expression optimization (`Compiler.Optimize.Typed.Expression`)

This is the heart of the transformation from `TypedCanonical` to `TypedOptimized`.

### 5.1 Module skeleton and entry points

Create `Compiler/Optimize/Typed/Expression.elm`:

```elm
module Compiler.Optimize.Typed.Expression exposing
    ( Cycle
    , optimize
    , optimizePotentialTailCallDef
    )

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedCanonical as TCan
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
import Compiler.Optimize.Typed.Names as Names
import Compiler.Reporting.Annotation as A
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Data.Map as Dict
import Data.Set as EverySet exposing (EverySet)
```

Define:

```elm
type alias Cycle =
    EverySet String Name.Name

optimize :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> TCan.Expr
    -> Names.Tracker TOpt.Expr
```

Note: `TCan.Expr = A.Located TCan.Expr_`, and `Expr_ = TypedExpr { expr : Can.Expr_, tipe : Can.Type }` .

So `optimize` starts:

```elm
optimize kernelEnv cycle annotations (A.At region (TCan.TypedExpr { expr = canExpr, tipe })) =
    case canExpr of
        Can.VarLocal name ->
            -- type of this occurrence is exactly `tipe`
            Names.pure (TOpt.TrackedVarLocal region name tipe)

        Can.VarTopLevel home name ->
            let
                defType =
                    lookupAnnotationType name annotations
            in
            if EverySet.member identity name cycle then
                Names.pure (TOpt.VarCycle region home name defType)
            else
                Names.registerGlobal region home name defType

        Can.VarKernel home name ->
            let
                kernelType =
                    KernelTypes.lookup ( home, name ) kernelEnv
            in
            Names.registerKernel home (TOpt.VarKernel region home name kernelType)

        -- ... mirror erased optimizer cases ...
```

Intent:

- For **non‑synthetic** expressions, always take the expression’s type from `tipe` (from TypedCanonical).
- Use `annotations`/`KernelTypeEnv` only where there is no `TCan.Expr` (e.g. top‑level types, kernel alias types).

### 5.2 Recursive structure (mirroring erased optimizer)

Walk through every `Can.Expr_` case from `Compiler.Optimize.Erased.Expression.optimize`  and port:

- `Can.List entries`:
    - traverse with `optimize kernelEnv cycle annotations` on each typed sub‑expr,
    - build `TOpt.List region optEntries listType`, where `listType` comes from the parent `tipe`.

- `Can.Call func args`:
    - optimize `func` and `args` recursively,
    - build `TOpt.Call region optFunc optArgs resultType`, where `resultType` is `tipe` of *this* call (from `TypedCanonical`).

- `Can.If branches final`:
    - each branch and final are `TCan.Expr` with their own `tipe`;
    - build `TOpt.If ...` with the enclosing `tipe` from `TypedCanonical`.

- `Can.Let`, `Can.LetRec`, `Can.LetDestruct`:
    - call specialized helpers that:
        - optimize defs via `optimizeDefHelp` / `optimizeRecDefHelp`,
        - ensure locals get types via pattern destructuring (see §5.3),
        - infer local def types from optimized RHS (`TOpt.typeOf`) for both tail and non‑tail cases (see §5.4).

- `Can.Case`:
    - optimize the scrutinee,
    - use typed destructuring helpers that return both destructors and `(Name, Can.Type)` bindings for branch patterns,
    - use `Names.withVarTypes` for bindings in each branch before optimizing the body, so `VarLocal` in branches see correct types.

Use the erased optimizer’s structure as a guide; when in doubt, copy the control flow and just “upgrade” each expression and local binding to carry a `Can.Type`.

### 5.3 Pattern‑aware destructuring with types

This is crucial for your “typed Names env with pattern‑aware destructuring” requirement.

In `Expression.elm` add a “DESTRUCTURING” section (as in the existing typed optimizer docs):

#### 5.3.1 Core helper: `destructHelpCollectBindings`

Define:

```elm
destructHelpCollectBindings :
    TOpt.Path
    -> Can.Type
    -> Can.Pattern
    -> ( List TOpt.Destructor, List ( Name, Can.Type ) )
    -> Names.Tracker ( List TOpt.Destructor, List ( Name, Can.Type ) )
```

It walks a pattern in lockstep with a **known scrutinee type** and accumulates:

- reverse list of `TOpt.Destructor`s describing how to extract subfields,
- list of `(Name, Can.Type)` for every **bound variable** in the pattern, including nested ones (tuples, lists, constructors, aliases, etc.).

Use `destruct-extract-type.md` as the template: refactor `destructHelpCollectBindings` to be the **single source of truth**, and have an untyped wrapper `destructHelp` delegate to it.

#### 5.3.2 Higher‑level helpers

Build on that:

- `destructPatternWithTypeAndBindings : TOpt.Path -> Can.Type -> Can.Pattern -> Names.Tracker ( List TOpt.Destructor, List ( Name, Can.Type ) )`
- `destruct` / `destructWithType` / `destructWithKnownType` — these should always feed the bindings into `Names.withVarTypes`.

For function arguments:

```elm
destructArgs :
    Annotations
    -> List Can.Pattern
    -> Names.Tracker
        ( List ( A.Located Name, Can.Type )
        , List TOpt.Destructor
        , List ( Name, Can.Type )
        )
```

Intent:

- For each argument pattern, compute:
    - the pattern name & type (for `TrackedFunction` arg list),
    - accumulated destructors (to insert `TOpt.Destruct` nodes that unpack tuples/records/etc.),
    - `bindings` for nested variables, to be added to the local context via `withVarTypes`.

`destructTypedArgs` is similar for `TCan.TypedDef` (explicit type annotations give you pattern types directly).

### 5.4 Local def types from RHS / patterns (no annotations for locals)

For non‑top‑level defs (like local `let` / `let rec`), you **must not** use `annotations` to get their types. The design docs already show how to fix this in the typed optimizer by:

- having `optimizeDefHelp` / `optimizeDefForTail` **compute types from the optimized RHS** using `TOpt.typeOf`,
- and, in tail‑call paths, using the `TOpt.Def`/`TOpt.TailDef`’s type as the source of truth.

Concretely, for the typed optimizer built over `TypedCanonical`:

- Implement `optimizeDefHelp` (non‑tail) something like:

  ```elm
  optimizeDefHelp :
      KernelTypes.KernelTypeEnv
      -> Cycle
      -> Annotations
      -> A.Region
      -> Name
      -> List Can.Pattern
      -> TCan.Expr
      -> Names.Tracker TOpt.Def
  optimizeDefHelp kernelEnv cycle annotations region name args tBodyExpr =
      case args of
          [] ->
              optimize kernelEnv cycle annotations tBodyExpr
                  |> Names.map
                      (\oexpr ->
                          let exprType = TOpt.typeOf oexpr in
                          TOpt.Def region name oexpr exprType
                      )

          _ ->
              destructArgs annotations args
                  |> Names.andThen
                      (\( typedArgNames, destructors, bindings ) ->
                          let
                              argTypes =
                                  List.map (\(loc, t) -> (A.toValue loc, t)) typedArgNames

                              allBindings =
                                  argTypes ++ bindings
                          in
                          Names.withVarTypes allBindings
                              (optimize kernelEnv cycle annotations tBodyExpr)
                              |> Names.map
                                  (\obody ->
                                      let
                                          bodyType = TOpt.typeOf obody
                                          funcType =
                                              buildFunctionType (List.map Tuple.second typedArgNames) bodyType

                                          ofunc =
                                              TOpt.TrackedFunction typedArgNames
                                                  (List.foldr (wrapDestruct bodyType) obody destructors)
                                                  funcType
                                      in
                                      TOpt.Def region name ofunc funcType
                                  )
                      )
  ```

- For tail‑call optimized defs, do the same but returning `TOpt.TailDef` and using `optimizeTail` to build the body. The **key point** is that `defType` is *derived from RHS + arg types*, **not** from annotations for locals, exactly as in `annotation-lookup-fix.md`.

- In all `Can.Let` / `Can.LetRec [def]` branches in `optimize` and `optimizeTail`, use the `TOpt.Def`/`TOpt.TailDef` you just built to get `(defName, defType)`:

  ```elm
  let
      ( defName, defType ) =
          case odef of
              TOpt.Def _ n _ t -> ( n, t )
              TOpt.TailDef _ n _ _ t -> ( n, t )
  in
  Names.withVarType defName defType (optimize ... body)
  ```

  This matches the design in `annotation-lookup-fix.md` and ensures local names like `res` never go through `lookupAnnotationType`.

---

## 6. How TypedCanonical feeds into all this

Where exactly do `TypedCanonical`’s types come into play?

- Every `TCan.Expr` carries a final `tipe : Can.Type` from the solver.
- In `optimize`, when you deconstruct `A.At region (TypedExpr { expr = canExpr, tipe })`, you:

    - **Use `tipe` as the result type** for any `TOpt.Expr` you build that corresponds 1‑to‑1 to this canonical node.
    - When recursing into subexpressions, you use their own `tipe`s.

Example: for a `Can.Call func args` node, the typed canonical view guarantees:

- `tFuncExpr : TCan.Expr` with `tipe = funcType` (a function type),
- each arg `tArg : TCan.Expr` with its own `tipe`,
- the call node `tCall : TCan.Expr` with `tipe = resultType`.

You then:

- recursively call `optimize` on `tFuncExpr` / `tArg`s,
- build `TOpt.Call region optFunc optArgs resultType`,
- never re‑infer `resultType` — you trust the solver.

For synthetic expressions (tail calls, destructors, alias records, etc.), you build their types from other `Can.Type` values:

- top‑level annotations (`annotations`) for top‑level defs and ports,
- function/ctor types embedded in union/alias definitions,
- `TOpt.typeOf` on RHS for locals.

All those `Can.Type` values ultimately come from the same solver run that produced `TypedCanonical`, so “types come from TypedCanonical” in the sense that *no new type inference happens in the optimizer*; you only transform and re‑pack existing `Can.Type`s.

---

## 7. Testing & sanity checks

Once implemented:

1. **Round‑trip type check**:
    - For a few sample modules, dump (`Debug.log` or JSON) the `tipe` on `TCan.Expr` and the type you attach to the corresponding `TOpt.Expr`. They should match for all non‑synthetic nodes.

2. **Local binding cases**:
    - Test recursive local `let` with tail calls (the `foldrHelper` / `res` scenario from the annotation‑lookup fix docs) and ensure no “Annotation not found” crashes and that locals get sensible types.

3. **Pattern‑bound locals**:
    - Functions like `second (_, y) = y` and `let (x, y) = expr in x + y`:
        - Their pattern‑bound locals should show up in the typed IR as `VarLocal x t` / `VarLocal y t` with correct tuple element types.

4. **Kernel types**:
    - Check a kernel alias like `List.cons`:
        - `KernelTypes.fromDecls` should populate its type,
        - `TOpt.VarKernel` should carry `a -> List a -> List a`.

5. **Monomorphization**:
    - Run monomorphization (`Compiler.Optimize.Mono`) on a `TOpt.LocalGraph` to verify it successfully unifies requested monomorphic types with node types.

---

If you’d like, I can next sketch concrete implementations for one or two representative cases (e.g. full `optimize` for `Can.Let`/`Can.Case` using `TCan.Expr` and the destruct helpers).

