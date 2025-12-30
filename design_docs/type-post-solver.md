Below is a concrete, implementable plan for a new `PostSolve` phase that:

- Runs once after the main type solver (`runWithIds`),
- Fixes all “missing” expression types (Group B),
- And computes kernel function types (`KernelTypeEnv`) in the same traversal.

I’ll always state:

- The module/file to edit or create,
- Exact function signatures,
- Where to hook them into the existing pipeline,
- Which existing kernel‑typing code is superseded and how.

I’ll base this on the current typed pipeline and typed optimizer code you already have.

---

## Step 0 – Recap of current typed pipeline and kernel typing

Today, the typed path does (logical view):

1. `Compiler.Type.Constrain.Module.constrainWithIds`
2. `Compiler.Type.Solve.runWithIds`
    - Returns `{ annotations, nodeTypes }` where `nodeTypes : Dict Int Int Can.Type`.
3. `Compiler.AST.TypedCanonical.fromCanonical canonical nodeTypes`
    - Uses expression IDs from `Can.Expr` to map to types via `nodeTypes` and build `TCan.Module` + `ExprTypes`.
4. `Compiler.Optimize.Typed.Module.optimizeTyped annotations exprTypes (TCan.Module tData)`:
    - Builds `kernelEnv` using:
        - `KernelTypes.fromDecls annotations tData.decls` (alias seeding),
        - `KernelTypes.inferFromUsage tData.decls exprTypes aliasEnv` (usage inference).
    - Then runs `addDecls` → `Typed.Expression.optimize` / `optimizePotentialTailCall` using that `kernelEnv`.

`Typed.Expression.optimize` still uses `ExprTypes` to rewrap subexpressions with types via `TCan.toTypedExpr exprTypes`.

We want to shift kernelEnv construction into a new `PostSolve` (type‑side) pass and at the same time fix Group B expression types.

---

## Step 1 – New module: `Compiler.Type.PostSolve`

**File:** `Compiler/Type/PostSolve.elm` (new)

**Purpose:**

- Take:

    - `annotations : Dict String Name.Name Can.Annotation`,
    - the *canonical* module (`Can.Module`),
    - `nodeTypes` from `Solve.runWithIds`.

- Return:

    - `fixedNodeTypes : Dict Int Int Can.Type` – original `nodeTypes` with Group B / kernel nodes fixed,
    - `kernelEnv : KernelTypes.KernelTypeEnv` – kernel function types derived from aliases and usage.

We run this **before** building `TypedCanonical`, so that `TCan.fromCanonical` sees the already‑fixed `nodeTypes`.

### 1.1 Module header and imports

Create `Compiler/Type/PostSolve.elm`:

```elm
module Compiler.Type.PostSolve exposing
    ( postSolve
    )

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
```

### 1.2 Public API

```elm
type alias NodeTypes =
    Dict Int Int Can.Type

postSolve :
    Dict String Name.Name Can.Annotation  -- annotations
    -> Can.Module                         -- canonical module
    -> NodeTypes                          -- nodeTypes from runWithIds
    ->
        { nodeTypes : NodeTypes
        , kernelEnv : KernelTypes.KernelTypeEnv
        }
```

- `NodeTypes` is the same shape as the `exprTypes`/`nodeTypes` you feed into `TypedCanonical.fromCanonical`.
- We’ll treat it as “node id → type”.

### 1.3 Implementation skeleton

```elm
postSolve annotations (Can.Module canData) nodeTypes0 =
    let
        -- Phase 0: seed kernel env from aliases (canonical decls)
        kernel0 : KernelTypes.KernelTypeEnv
        kernel0 =
            seedKernelAliases annotations canData.decls

        -- Phase 1: fix expression types + infer kernel types from usage
        ( nodeTypes1, kernel1 ) =
            postSolveDecls annotations canData.decls nodeTypes0 kernel0
    in
    { nodeTypes = nodeTypes1
    , kernelEnv = kernel1
    }
```

`seedKernelAliases` and `postSolveDecls` are defined below.

---

## Step 2 – Move / adapt kernel alias seeding into PostSolve

Currently alias seeding is in `Compiler.Optimize.Typed.KernelTypes.fromDecls` and works over `TCan.Decls`.

We want a canonical‑level variant so PostSolve can run before `TypedCanonical`.

### 2.1 Alias seeding over `Can.Decls`

Add in `PostSolve.elm`:

```elm
seedKernelAliases :
    Dict String Name.Name Can.Annotation
    -> Can.Decls
    -> KernelTypes.KernelTypeEnv
seedKernelAliases annotations decls =
    let
        stepDef : Can.Def -> KernelTypes.KernelTypeEnv -> KernelTypes.KernelTypeEnv
        stepDef def env =
            case def of
                -- Untyped def, 0 args, body is exactly a VarKernel
                Can.Def (A.At _ name) [] (A.At _ (Can.VarKernel home kernelName)) ->
                    case Dict.get Name.toString name annotations of
                        Just (Can.Forall _ tipe) ->
                            KernelTypes.insertFirstUsage home kernelName tipe env
                        Nothing ->
                            env

                -- TypedDef, 0 args, body is exactly a VarKernel
                Can.TypedDef (A.At _ name) _ [] (A.At _ (Can.VarKernel home kernelName)) resultType ->
                    KernelTypes.insertFirstUsage home kernelName resultType env

                _ ->
                    env

        stepDecls : Can.Decls -> KernelTypes.KernelTypeEnv -> KernelTypes.KernelTypeEnv
        stepDecls ds env =
            case ds of
                Can.Declare def rest ->
                    stepDecls rest (stepDef def env)

                Can.DeclareRec d ds rest ->
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

Notes:

- This mirrors the alias‑seeding logic from your original `kernel-types.md` / `fromDecls` design, but over `Can.Decls`.
- It uses `KernelTypes.insertFirstUsage` to avoid overwriting usage‑based entries. That helper already exists in `Compiler.Optimize.Typed.KernelTypes`.

You may need a helper `Name.toString` or use the identity function to look up `name` in `annotations`, depending on how that map is keyed; mirror what `KernelTypes.checkKernelAlias` does today.

---

## Step 3 – PostSolve over declarations and expressions

Now define a traversal over `Can.Decls` → `Can.Def` → `Can.Expr` that both:

- Reconstructs missing expression types (Group B + VarKernel),
- Infers kernel function types from direct calls.

We **only** update `nodeTypes` (id → type); `TypedCanonical.fromCanonical` will later use that map to build `TCan.Module`.

### 3.1 Decls driver

In `PostSolve.elm`:

```elm
postSolveDecls :
    Dict String Name.Name Can.Annotation
    -> Can.Decls
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveDecls annotations decls nodeTypes0 kernel0 =
    case decls of
        Can.Declare def rest ->
            let
                ( nodeTypes1, kernel1 ) =
                    postSolveDef annotations def nodeTypes0 kernel0
            in
            postSolveDecls annotations rest nodeTypes1 kernel1

        Can.DeclareRec d ds rest ->
            let
                ( nodeTypes1, kernel1 ) =
                    List.foldl
                        (\def (nt, ke) -> postSolveDef annotations def nt ke)
                        ( nodeTypes0, kernel0 )
                        (d :: ds)
            in
            postSolveDecls annotations rest nodeTypes1 kernel1

        Can.SaveTheEnvironment ->
            ( nodeTypes0, kernel0 )
```

### 3.2 Def driver

```elm
postSolveDef :
    Dict String Name.Name Can.Annotation
    -> Can.Def
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveDef annotations def nodeTypes0 kernel0 =
    case def of
        Can.Def _ _ body ->
            postSolveExpr annotations body nodeTypes0 kernel0

        Can.TypedDef _ _ _ body _ ->
            postSolveExpr annotations body nodeTypes0 kernel0
```

We don’t change def types here; just fix expression nodes and update `kernelEnv`. Local def types will be reconstructed later in the typed optimizer from RHS, as per your existing design.

---

## Step 4 – Core: `postSolveExpr` over `Can.Expr`

We now work over *canonical* expressions:

```elm
postSolveExpr :
    Dict String Name.Name Can.Annotation
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveExpr annotations ((A.At region info) as expr) nodeTypes0 kernel0 =
    let
        exprId : Int
        exprId =
            info.id

        node : Can.Expr_
        node =
            info.node
    in
    case node of
        -- Group A: exprId already has a meaningful var in constraints.
        -- We TRUST nodeTypes0[exprId] and just recurse into children to fix them.

        Can.Int _ ->
            ( nodeTypes0, kernel0 )

        Can.Negate e ->
            postSolveExpr annotations e nodeTypes0 kernel0

        Can.Binop _ _ _ _ left right ->
            let
                ( nt1, ke1 ) =
                    postSolveExpr annotations left nodeTypes0 kernel0
            in
            postSolveExpr annotations right nt1 ke1

        Can.Call func args ->
            postSolveCall annotations region expr exprId func args nodeTypes0 kernel0

        Can.If branches final ->
            postSolveIf annotations region branches final nodeTypes0 kernel0

        Can.Case scrut branches ->
            postSolveCase annotations region scrut branches nodeTypes0 kernel0

        Can.Access record (A.At _ _) ->
            postSolveExpr annotations record nodeTypes0 kernel0

        Can.Update record fields ->
            postSolveUpdate annotations record fields nodeTypes0 kernel0

        -- VarKernel: type is NOT determined by solver; we will overwrite nodeTypes for this id later
        -- using kernelEnv, so just return for now (kernelEnv is updated in Call).

        Can.VarKernel _ _ ->
            ( nodeTypes0, kernel0 )

        -- Group B + others: reconstruct this node's type structurally

        Can.Str _ ->
            let
                strType = Can.TType ModuleName.string Name.string []
                nt1 = Dict.insert identity exprId strType nodeTypes0
            in
            ( nt1, kernel0 )

        Can.Chr _ ->
            let
                chrType = Can.TType ModuleName.char Name.char []
                nt1 = Dict.insert identity exprId chrType nodeTypes0
            in
            ( nt1, kernel0 )

        Can.Float _ ->
            let
                floatType = Can.TType ModuleName.float Name.float []
                nt1 = Dict.insert identity exprId floatType nodeTypes0
            in
            ( nt1, kernel0 )

        Can.List elems ->
            postSolveList annotations exprId elems nodeTypes0 kernel0

        Can.Record fields ->
            postSolveRecord annotations exprId fields nodeTypes0 kernel0

        Can.Tuple a b cs ->
            postSolveTuple annotations exprId a b cs nodeTypes0 kernel0

        Can.Lambda args body ->
            postSolveLambda annotations exprId args body nodeTypes0 kernel0

        Can.Let def body ->
            let
                ( nt1, ke1 ) =
                    postSolveDef annotations def nodeTypes0 kernel0
            in
            postSolveExpr annotations body nt1 ke1

        Can.LetRec defs body ->
            let
                ( nt1, ke1 ) =
                    List.foldl
                        (\d (nt, ke) -> postSolveDef annotations d nt ke)
                        ( nodeTypes0, kernel0 )
                        defs
            in
            postSolveExpr annotations body nt1 ke1

        Can.LetDestruct pattern bound body ->
            let
                ( nt1, ke1 ) =
                    postSolveExpr annotations bound nodeTypes0 kernel0
            in
            postSolveExpr annotations body nt1 ke1

        Can.Accessor _ ->
            -- Accessor is a function; we can reconstruct from record + field types once needed.
            -- For now, you may keep solver's type as-is or add a structural rule later.
            ( nodeTypes0, kernel0 )

        Can.Shader _ _ ->
            -- Keep solver's type; no additional reconstruction.
            ( nodeTypes0, kernel0 )

        -- ... handle any remaining constructors similarly ...
```

This is sketched; each helper (`postSolveList`, `postSolveRecord`, etc.) will:

- Recursively call `postSolveExpr` on children,
- Compute the node’s type from child types and known constructors,
- Write it into `nodeTypes` at `exprId`.

### 4.1 Example: lists

```elm
postSolveList :
    Dict String Name.Name Can.Annotation
    -> Int
    -> List Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveList annotations exprId elems nodeTypes0 kernel0 =
    let
        step e (nt, ke) =
            postSolveExpr annotations e nt ke

        ( nodeTypes1, kernel1 ) =
            List.foldl step (nodeTypes0, kernel0) elems

        elemType : Can.Type
        elemType =
            case elems of
                [] ->
                    -- For empty list, keep whatever solver inferred (may be TVar or from annotation)
                    case Dict.get identity exprId nodeTypes1 of
                        Just t ->
                            t
                        Nothing ->
                            Can.TVar "a" -- fallback

                (A.At _ info) :: _ ->
                    -- Look up type of first element
                    case Dict.get identity info.id nodeTypes1 of
                        Just t ->
                            t
                        Nothing ->
                            Can.TVar "a"
        listType : Can.Type
        listType =
            Can.TApp ModuleName.list Name.list [ elemType ]

        nodeTypes2 =
            Dict.insert identity exprId listType nodeTypes1
    in
    ( nodeTypes2, kernel1 )
```

You can refine the empty‑list behavior later; this gives you a structural type for non‑empty lists and preserves existing inference for `[]`.

### 4.2 Example: tuples

```elm
postSolveTuple :
    Dict String Name.Name Can.Annotation
    -> Int
    -> Can.Expr
    -> Can.Expr
    -> List Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveTuple annotations exprId a b cs nodeTypes0 kernel0 =
    let
        ( nodeTypes1, kernel1 ) =
            postSolveExpr annotations a nodeTypes0 kernel0

        ( nodeTypes2, kernel2 ) =
            postSolveExpr annotations b nodeTypes1 kernel1

        step c (nt, ke) =
            postSolveExpr annotations c nt ke

        ( nodeTypes3, kernel3 ) =
            List.foldl step (nodeTypes2, kernel2) cs

        getType e =
            case e of
                A.At _ info ->
                    Dict.get identity info.id nodeTypes3
                        |> Maybe.withDefault (Can.TVar "a")

        aType = getType a
        bType = getType b
        restTypes = List.map getType cs

        tupleType =
            Can.TTuple aType bType restTypes

        nodeTypes4 =
            Dict.insert identity exprId tupleType nodeTypes3
    in
    ( nodeTypes4, kernel3 )
```

Follow the same pattern for records, lambdas, etc., using the same structural types your constraint generator uses in `constrainNodeWithIdsProg` (lists, records, tuples, lambdas, accessors, etc.).

---

## Step 5 – Kernel usage inference inside `postSolveExpr`

Now fold the existing `KernelTypes.inferFromUsage` logic into `postSolveExpr`, specifically in the `Can.Call` case.

### 5.1 Add a `postSolveCall` helper

```elm
postSolveCall :
    Dict String Name.Name Can.Annotation
    -> A.Region
    -> Can.Expr                 -- full call node for context
    -> Int                      -- exprId of call
    -> Can.Expr                 -- func
    -> List Can.Expr            -- args
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveCall annotations region wholeExpr exprId func args nodeTypes0 kernel0 =
    let
        -- First post-solve func and args
        ( nodeTypes1, kernel1 ) =
            postSolveExpr annotations func nodeTypes0 kernel0

        step arg (nt, ke) =
            postSolveExpr annotations arg nt ke

        ( nodeTypes2, kernel2 ) =
            List.foldl step (nodeTypes1, kernel1) args

        -- Helper to lookup type by expr id
        lookupType id nt =
            Dict.get identity id nt
                |> Maybe.withDefault (Can.TVar "a")
    in
    case func of
        A.At _ funcInfo ->
            case funcInfo.node of
                Can.VarKernel home name ->
                    -- Direct kernel call: infer full function type
                    let
                        argTypes : List Can.Type
                        argTypes =
                            List.map
                                (\a ->
                                    case a of
                                        A.At _ info ->
                                            lookupType info.id nodeTypes2
                                )
                                args

                        callResultType : Can.Type
                        callResultType =
                            lookupType exprId nodeTypes2

                        candidateType : Can.Type
                        candidateType =
                            KernelTypes.buildFunctionType argTypes callResultType

                        kernel3 : KernelTypes.KernelTypeEnv
                        kernel3 =
                            KernelTypes.insertFirstUsage home name candidateType kernel2
                    in
                    ( nodeTypes2, kernel3 )

                _ ->
                    ( nodeTypes2, kernel2 )
```

- `buildFunctionType` and `insertFirstUsage` already exist in `Compiler.Optimize.Typed.KernelTypes` per your mini‑solver design.
- This mirrors the logic in `KernelTypes.inferFromUsage` but uses canonical expressions + `NodeTypes` instead of `TCan.Expr`.

### 5.2 Assign kernel expression types

We still need to give each `VarKernel` expression node a real type, using `kernelEnv`. Add a second pass or integrate directly into `postSolveExpr`’s `Can.VarKernel` branch:

```elm
Can.VarKernel home name ->
    let
        kernelType : Can.Type
        kernelType =
            case KernelTypes.lookup home name kernel0 of
                Just t ->
                    t

                Nothing ->
                    -- No alias and no usage; internal bug / unsupported shape
                    Can.TVar ("kernel_" ++ Name.toChars home ++ "_" ++ Name.toChars name)

        nodeTypes1 =
            Dict.insert identity exprId kernelType nodeTypes0
    in
    ( nodeTypes1, kernel0 )
```

- This mirrors the `Typed.Expression.optimizeExpr` VarKernel case today, except the type comes from `kernelEnv` instead of from an unconstrained TVar.

If you prefer to treat missing entries as a hard compiler crash (like the current optimizer does), you can replace the fallback TVar with `Utils.Crash.crash`.

---

## Step 6 – Wire PostSolve into the typed pipeline

Now we integrate `PostSolve` into the existing typed type‑checking & optimization flow.

### 6.1 In `Compile.typeCheckTyped`

Docs show it currently as:

```elm
typeCheckTyped modul canonical =
    let
        ioResult =
            Type.constrainWithIds canonical
                |> TypeCheck.andThen
                    (\( constraint, nodeVars ) ->
                        Type.runWithIds constraint nodeVars
                    )
                |> TypeCheck.unsafePerformIO
    in
    case ioResult of
        Err errors ->
            ...
        Ok { annotations, nodeTypes } ->
            let
                typedCanonical =
                    TCan.fromCanonical canonical nodeTypes
            in
            Ok { annotations = annotations, typedCanonical = typedCanonical }
```

Change this to call `PostSolve.postSolve` *before* `fromCanonical` and also return `kernelEnv`:

```elm
import Compiler.Type.PostSolve as PostSolve
import Compiler.Optimize.Typed.KernelTypes as KernelTypes

type alias TypedCheckResult =
    { annotations  : Dict String Name.Name Can.Annotation
    , typedCanonical : TCan.Module
    , exprTypes    : TCan.ExprTypes
    , kernelEnv    : KernelTypes.KernelTypeEnv
    }

typeCheckTyped modul canonical =
    let
        ioResult =
            Type.constrainWithIds canonical
                |> TypeCheck.andThen
                    (\( constraint, nodeVars ) ->
                        Type.runWithIds constraint nodeVars
                    )
                |> TypeCheck.unsafePerformIO
    in
    case ioResult of
        Err errors ->
            Err (E.BadTypes (Localizer.fromModule modul) errors)

        Ok { annotations, nodeTypes } ->
            let
                -- PostSolve over canonical AST + nodeTypes
                { nodeTypes = fixedNodeTypes, kernelEnv } =
                    PostSolve.postSolve annotations canonical nodeTypes

                typedCanonical =
                    TCan.fromCanonical canonical fixedNodeTypes

                exprTypes =
                    fixedNodeTypes -- alias for clarity; same underlying dict
            in
            Ok
                { annotations  = annotations
                , typedCanonical = typedCanonical
                , exprTypes    = exprTypes
                , kernelEnv    = kernelEnv
                }
```

Notes:

- `exprTypes` here is the same map you pass to the typed optimizer as `ExprTypes`. `TCan.fromCanonical` still uses it to build per‑expression `tipe`.
- We now also produce `kernelEnv` at type‑check time.

If your actual pipeline separates “type check” and “typed optimize” calls, you can instead:

- Keep `typeCheckTyped` returning `{ annotations, nodeTypes }` as before,
- And introduce a new function (e.g. `Compile.prepareTyped`) that calls `PostSolve` + `fromCanonical` + `optimizeTyped`.

The key is: **typed optimization should no longer build kernelEnv itself; it gets it from PostSolve**.

---

## Step 7 – Update typed optimizer to take `kernelEnv` from PostSolve

**File:** `Compiler/Optimize/Typed/Module.elm`

It currently computes `kernelEnv` internally:

```elm
optimizeTyped : Annotations -> ExprTypes -> TCan.Module -> MResult i (List W.Warning) TOpt.LocalGraph
optimizeTyped annotations exprTypes (TCan.Module tData) =
    let
        aliasEnv = KernelTypes.fromDecls annotations tData.decls
        kernelEnv = KernelTypes.inferFromUsage tData.decls exprTypes aliasEnv
    in
    ...
        |> addDecls tData.name annotations exprTypes kernelEnv tData.decls
```

### 7.1 Change `optimizeTyped` signature and body

Change to **accept** `kernelEnv` from caller and stop constructing it:

```elm
optimizeTyped :
    Annotations
    -> ExprTypes
    -> KernelTypes.KernelTypeEnv
    -> TCan.Module
    -> MResult i (List W.Warning) TOpt.LocalGraph
optimizeTyped annotations exprTypes kernelEnv (TCan.Module tData) =
    TOpt.LocalGraph
        { main = Nothing
        , nodes = Dict.empty
        , fields = Dict.empty
        , annotations = annotations
        }
        |> addAliases tData.name annotations tData.aliases
        |> addUnions tData.name annotations tData.unions
        |> addEffects tData.name annotations tData.effects
        |> addDecls tData.name annotations exprTypes kernelEnv tData.decls
```

- Remove the local `aliasEnv` and `kernelEnv` computation.
- `addDecls` signature already takes `exprTypes` and `kernelEnv`.

### 7.2 Adjust wherever `optimizeTyped` is called

Wherever you currently do:

```elm
Optimize.Typed.Module.optimizeTyped annotations exprTypes typedCanonical
```

change to:

```elm
Optimize.Typed.Module.optimizeTyped annotations exprTypes kernelEnv typedCanonical
```

using the `kernelEnv` returned from `PostSolve.postSolve` (either via `typeCheckTyped` or a new combined function).

---

## Step 8 – Trim `Compiler.Optimize.Typed.KernelTypes`

**File:** `Compiler/Optimize/Typed/KernelTypes.elm`

This module currently:

- Defines `KernelTypeEnv`,
- Implements `fromDecls : Annotations -> TCan.Decls -> KernelTypeEnv`,
- Implements `inferFromUsage : TCan.Decls -> ExprTypes -> KernelTypeEnv -> KernelTypeEnv`,
- And helpers: `lookup`, `hasEntry`, `insertFirstUsage`, `buildFunctionType`.

After this refactor:

- Construction of `kernelEnv` (alias + usage) is done in `PostSolve` over **canonical** decls + nodeTypes.
- Typed optimizer no longer calls `KernelTypes.fromDecls` or `inferFromUsage`.

So:

1. **Keep**:

    - `type alias KernelTypeEnv`,
    - `lookup : Name -> Name -> KernelTypeEnv -> Maybe Can.Type`,
    - `hasEntry`, `insertFirstUsage`, `buildFunctionType`.

   These are now utility functions reused by `PostSolve`.

2. **Optionally remove or deprecate**:

    - `fromDecls`,
    - `inferFromUsage`.

   If nothing else calls them, you can safely delete their definitions and stop exporting them, leaving only:

   ```elm
   module Compiler.Optimize.Typed.KernelTypes exposing
       ( KernelTypeEnv
       , lookup
       , hasEntry
       , insertFirstUsage
       , buildFunctionType
       )
   ```

   and adjust imports accordingly.

---

## Step 9 – Sanity checks and incremental rollout

1. **Constraint and solver unchanged**

    - No changes to `Compiler.Type.Constrain.Expression` or `Compiler.Type.Solve`. They still generate and solve constraints exactly as before and return `nodeTypes`. Group A vs Group B logic remains as you have it now.

2. **TypedCanonical remains unchanged**

    - `TypedCanonical.fromCanonical` still takes `Dict Int Int Can.Type` – now *post‑solved* `fixedNodeTypes` – and builds `TCan.Module` + `ExprTypes`.
    - You do not need to change `TCan.Expr` structure or `toTypedExpr`.

3. **Typed optimizer**

    - Continues to use `ExprTypes` and `TCan.toTypedExpr exprTypes` to rewrap subexpressions.
    - For `VarKernel`, it still uses `KernelTypes.lookup home name kernelEnv` as today; the only difference is `kernelEnv` now arrives from PostSolve.

4. **Coverage of Group B**

    - Ensure `postSolveExpr` has cases for all Group B forms identified in your `type-all-exprs-rethink` doc: strings, chars, floats, lists, records, tuples, lambdas, accessors, annotated if/case, lets, shaders, etc.
    - For each, mirror the composite types you currently build in `constrainNodeWithIdsProg` (e.g. `RecordN` for records, `AppN list [...]` for lists).

5. **Kernel types sanity**

    - Verify that for a kernel alias:

      ```elm
      cons : a -> List a -> List a
      cons = Elm.Kernel.List.cons
      ```

      `PostSolve.seedKernelAliases` inserts `a -> List a -> List a` for `(home="List", name="cons")` into `kernelEnv`.

    - For an unaliased kernel with direct calls, e.g. `Elm.Kernel.Basics.log`, check that `postSolveCall` reconstructs the full function type from arg and call result types and `insertFirstUsage` stores it.

---

## 10 – Summary

Following these steps:

- You introduce a **single PostSolve pass** (`Compiler.Type.PostSolve`) that:
    - walks canonical decls + expressions,
    - fixes all Group B / VarKernel expression types in `nodeTypes`,
    - and builds `KernelTypeEnv` via alias seeding + usage inference.

- You modify the typed pipeline so that:
    - `runWithIds` → `PostSolve.postSolve` → `TypedCanonical.fromCanonical`,
    - `Typed.Module.optimizeTyped` receives `kernelEnv` from PostSolve and no longer computes it.

- You trim `Compiler.Optimize.Typed.KernelTypes` to be just env + helpers; the heavy lifting moves into `PostSolve`, but typed optimization still depends on the **same** `KernelTypeEnv` type and `lookup` API.

This gives you:

- Correct, fully‑populated types for *all* expression nodes as seen by TypedCanonical and typed optimization.
- Kernel function types computed in the same conceptual phase as other post‑solve fixes, without touching the core HM solver or constraint generator.

