Here’s a complete, end‑to‑end design for generating a *typed canonical* form, using expression IDs embedded in the canonical AST and the existing HM type checker.

The design is broken into concrete steps, with specific modules and intent called out.

---

## 1. Goals & invariants

We want:

- A new `TypedCanonical` AST where every canonical expression carries a `Can.Type`.
- No behavior change in type checking:
    - Same error messages and locations.
    - Same top‑level `Can.Annotation`s.
- All type inference remains in the existing **constrain + solve** pipeline:
    - `Compiler.Type.Constrain.Module.constrain : Can.Module -> IO Constraint` builds constraints.
    - `Compiler.Type.Solve.run : Constraint -> IO (Result _ (Dict String Name.Name Can.Annotation))` solves them.
- We add:
    - A mapping from each canonical expression ID → solver `Variable`,
    - A way to convert those `Variable`s to `Can.Type`, and
    - A `TypedCanonical` view built from `Can.Module` + that map.

We accept that this will change the shape of `Can.Expr` and therefore touch canonicalization and constraint generation.

---

## 2. Extend canonical expressions with IDs

### 2.1. Change `Compiler.AST.Canonical.Expr`

Current definition (simplified):

```elm
-- Compiler.AST.Canonical

type alias Expr =
    A.Located Expr_

type Expr_
    = VarLocal Name
    | VarTopLevel IO.Canonical Name
    | VarKernel Name Name
    | VarForeign IO.Canonical Name Annotation
    | VarCtor CtorOpts IO.Canonical Name Index.ZeroBased Annotation
    | VarDebug IO.Canonical Name Annotation
    | VarOperator Name IO.Canonical Name Annotation
    | Chr String
    | Str String
    | Int Int
    | Float Float
    | List (List Expr)
    | Negate Expr
    | Binop Name IO.Canonical Name Annotation Expr Expr
    | Lambda (List Pattern) Expr
    | Call Expr (List Expr)
    | If (List ( Expr, Expr )) Expr
    | Let Def Expr
    | LetRec (List Def) Expr
    | LetDestruct Pattern Expr Expr
    | Case Expr (List CaseBranch)
    | Accessor Name
    | Access Expr (A.Located Name)
    | Update Expr (Dict String (A.Located Name) FieldUpdate)
    | Record (Dict String (A.Located Name) Expr)
    | Unit
    | Tuple Expr Expr (List Expr)
    | Shader Shader.Source Shader.Types
``` 

Change this to introduce an `ExprInfo` record with an ID:

```elm
type alias Expr =
    A.Located ExprInfo

type alias ExprInfo =
    { id : Int
    , node : Expr_
    }

type Expr_
    = VarLocal Name
    | VarTopLevel IO.Canonical Name
    | VarKernel Name Name
    | VarForeign IO.Canonical Name Annotation
    | VarCtor CtorOpts IO.Canonical Name Index.ZeroBased Annotation
    | VarDebug IO.Canonical Name Annotation
    | VarOperator Name IO.Canonical Name Annotation
    | Chr String
    | Str String
    | Int Int
    | Float Float
    | List (List Expr)
    | Negate Expr
    | Binop Name IO.Canonical Name Annotation Expr Expr
    | Lambda (List Pattern) Expr
    | Call Expr (List Expr)
    | If (List ( Expr, Expr )) Expr
    | Let Def Expr
    | LetRec (List Def) Expr
    | LetDestruct Pattern Expr Expr
    | Case Expr (List CaseBranch)
    | Accessor Name
    | Access Expr (A.Located Name)
    | Update Expr (Dict String (A.Located Name) FieldUpdate)
    | Record (Dict String (A.Located Name) Expr)
    | Unit
    | Tuple Expr Expr (List Expr)
    | Shader Shader.Source Shader.Types
```

Add convenience helpers:

```elm
exprId : Expr -> Int
exprId (A.At _ info) =
    info.id

exprNode : Expr -> Expr_
exprNode (A.At _ info) =
    info.node
```

**Intent**:

- Give every canonical expression a unique `Int` ID that will be stable through all later phases.
- Keep the actual expression variants (`Expr_`) unchanged so all existing pattern matches can be updated to go through `info.node`.

**Mechanical impact**:

- Anywhere that used to pattern match on `A.At region expr_` now needs to match `A.At region info` and then inspect `info.node`.
- If you want a smoother transition, you can temporarily write:

  ```elm
  canonicalize ... (A.At region expr_) =
      -- old code
  ```

  as:

  ```elm
  canonicalize ... ((A.At region info) as expr) =
      case info.node of
          ...
  ```

  and gradually refactor.

There are no existing encoders/decoders for `Expr` in `Canonical.elm` (only for types and declarations) so you don’t need to update binary serialization here.

---

## 3. Assign IDs in canonicalization

Now we need canonicalization to actually fill in these IDs when building `Can.Expr`.

The main expression canonicalizer is `Compiler.Canonicalize.Expression`:

```elm
canonicalize :
    SyntaxVersion
    -> Env.Env
    -> Src.Expr
    -> EResult FreeLocals (List W.Warning) Can.Expr

canonicalize syntaxVersion env (A.At region expression) =
    ReportingResult.map (A.At region) <|
        case expression of
            Src.Str string _ ->
                ReportingResult.ok (Can.Str string)

            Src.Chr char ->
                ReportingResult.ok (Can.Chr char)

            ...
``` 

### 3.1. Introduce an internal ID state

In `Compiler.Canonicalize.Expression`:

```elm
type alias IdState =
    { nextId : Int }

initialIdState : IdState
initialIdState =
    { nextId = 0 }
```

Change the public `canonicalize` to delegate to an ID‑aware helper and drop the state:

```elm
canonicalize :
    SyntaxVersion
    -> Env.Env
    -> Src.Expr
    -> EResult FreeLocals (List W.Warning) Can.Expr
canonicalize syntaxVersion env srcExpr =
    canonicalizeWithIds syntaxVersion env initialIdState srcExpr
        |> ReportingResult.map Tuple.first
```

Define:

```elm
canonicalizeWithIds :
    SyntaxVersion
    -> Env.Env
    -> IdState
    -> Src.Expr
    -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
canonicalizeWithIds syntaxVersion env idState (A.At region expression) =
    case expression of
        Src.Str string _ ->
            let
                id =
                    idState.nextId

                info : Can.ExprInfo
                info =
                    { id = id
                    , node = Can.Str string
                    }

                nextState =
                    { idState | nextId = id + 1 }
            in
            ReportingResult.ok ( A.At region info, nextState )

        Src.Chr char ->
            -- similar pattern ...

        Src.Call func args ->
            canonicalizeWithIds syntaxVersion env idState func
                |> ReportingResult.andThen
                    (\( canFunc, state1 ) ->
                        traverseWithIds syntaxVersion env state1 args
                            |> ReportingResult.map
                                (\( canArgs, state2 ) ->
                                    let
                                        id = state2.nextId

                                        info =
                                            { id = id
                                            , node = Can.Call canFunc canArgs
                                            }

                                        nextState =
                                            { state2 | nextId = id + 1 }
                                    in
                                    ( A.At region info, nextState )
                                )
                    )

        -- etc...
```

`traverseWithIds` is a helper that folds over children, threading `IdState` and accumulating a `List Can.Expr`.

**Intent**:

- Ensure **every** `Can.Expr` node in a module receives a unique `id` when canonicalization constructs it.
- Keep canonicalization semantics identical; only add IDs.

### 3.2. Other places that construct `Can.Expr`

Search for `Can.Str`, `Can.Call`, etc. outside `Compiler.Canonicalize.Expression`. If any other canonicalization code constructs canonical expressions (e.g. some port or effect helpers), refactor them to either:

- Go through `canonicalizeWithIds` (if they start from `Src.Expr`), or
- Use a shared helper like:

  ```elm
  makeExpr : A.Region -> IdState -> Can.Expr_ -> ( Can.Expr, IdState )
  makeExpr region state node =
      let
          id = state.nextId
          info = { id = id, node = node }
      in
      ( A.At region info, { state | nextId = id + 1 } )
  ```

so ID assignment is always consistent.

---

## 4. Associate solver variables with expression IDs

Next, extend constraint generation so each `Can.Expr` ID is tied to one solver variable representing its type.

### 4.1. Introduce `ExprVarMap`

In `Compiler.Type.Constrain.Expression`:

```elm
type alias ExprVarMap =
    Dict Int IO.Variable
```

We’ll thread this map through constraint generation.

### 4.2. Change the top‑level expression constraint function

Currently:

```elm
constrain :
    RTV
    -> Can.Expr
    -> E.Expected Type
    -> IO Constraint
constrain rtv (A.At region expression) expected =
    case expression of
        Can.VarLocal name -> ...
``` 

Change to:

```elm
constrainWithVars :
    RTV
    -> Can.Expr
    -> E.Expected Type
    -> ExprVarMap
    -> IO ( Constraint, ExprVarMap )
constrainWithVars rtv ((A.At region info) as expr) expected exprVars0 =
    let
        id : Int
        id =
            info.id
    in
    Type.mkFlexVar
        |> IO.andThen
            (\exprVar ->
                let
                    exprType : Type
                    exprType =
                        VarN exprVar

                    exprVars1 : ExprVarMap
                    exprVars1 =
                        Dict.insert identity id exprVar exprVars0
                in
                constrainNode rtv region info.node exprType expected exprVars1
            )
```

Define `constrainNode` as a new helper that mirrors the old `case expression of` but now has explicit `exprType`:

```elm
constrainNode :
    RTV
    -> A.Region
    -> Can.Expr_
    -> Type              -- exprType: the type var for this expression
    -> E.Expected Type   -- expected: the "expected type" from context
    -> ExprVarMap
    -> IO ( Constraint, ExprVarMap )
```

Examples:

- **Literal**:

  ```elm
  constrainNode rtv region (Can.Str _) exprType expected exprVars =
      let
          litCon =
              CEqual region E.String Type.string (E.NoExpectation exprType)
      in
      IO.pure
          ( Type.exists []
                (CAnd
                    [ litCon
                    , CEqual region E.String exprType expected
                    ]
                )
          , exprVars
          )
  ```

- **Local variable**:

  ```elm
  constrainNode rtv region (Can.VarLocal name) exprType expected exprVars =
      -- CLocal already "remembers" a name; we just ensure exprType matches expected.
      let
          localCon =
              CLocal region name (E.NoExpectation exprType)
      in
      IO.pure
          ( Type.exists []
                (CAnd
                    [ localCon
                    , CEqual region (E.Local name) exprType expected
                    ]
                )
          , exprVars
          )
  ```

- **Call**: reuse `constrainCall` logic, but:

    - When you create the result type variable (`resultVar` → `resultType`), you unify it with `exprType`.
    - At the end, unify `exprType` with `expected` as usual.

You repeat this pattern for each expression form (`List`, `Negate`, `Binop`, `Lambda`, `If`, `Case`, `Let`, `LetRec`, `Record`, `Update`, etc.) so that:

- **Invariant**: for every `Can.Expr` in the module, there is exactly one solver `Variable` inserted into `ExprVarMap` keyed by `info.id`, and that variable is constrained to equal the expression’s type.

### 4.3. Update `constrainDef` / `constrainRecursiveDefs`

`Compiler.Type.Constrain.Expression` also has definition/recursion entry points (for lets, top‑level decls) .

Add variants that work with `ExprVarMap`, e.g.:

```elm
constrainDefWithVars :
    RTV -> Can.Def -> Constraint -> ExprVarMap -> IO ( Constraint, ExprVarMap )

constrainRecursiveDefsWithVars :
    RTV -> List Can.Def -> Constraint -> ExprVarMap -> IO ( Constraint, ExprVarMap )
```

Inside these, everywhere you previously called `constrain rtv expr expected`, now call `constrainWithVars rtv expr expected`.

---

## 5. Collect the ExprVarMap at module level

Now adapt `Compiler.Type.Constrain.Module` to use the new expression constraint API.

Current entry point:

```elm
constrain : Can.Module -> IO Constraint
constrain (Can.Module canData) =
    case canData.effects of
        Can.NoEffects ->
            constrainDecls canData.decls CSaveTheEnvironment
        ...
``` 

### 5.1. Add `constrainWithExprVars`

```elm
type alias ExprVarMap =
    Dict Int IO.Variable

constrainWithExprVars :
    Can.Module
    -> IO ( Constraint, ExprVarMap )
constrainWithExprVars (Can.Module canData) =
    let
        initialMap : ExprVarMap
        initialMap =
            Dict.empty
    in
    case canData.effects of
        Can.NoEffects ->
            constrainDeclsWithVars canData.decls CSaveTheEnvironment initialMap

        Can.Ports ports ->
            Dict.foldr compare
                (\name port make ->
                    letPortWithVars name port make
                )
                (constrainDeclsWithVars canData.decls CSaveTheEnvironment initialMap)
                ports

        Can.Manager r0 r1 r2 manager ->
            -- similar composition using constrainEffects and letCmd/letSub,
            -- threading ExprVarMap through unchanged
            ...
```

Define `constrainDeclsWithVars` analogous to `constrainDecls`:

```elm
constrainDeclsWithVars :
    Can.Decls
    -> Constraint
    -> ExprVarMap
    -> IO ( Constraint, ExprVarMap )
constrainDeclsWithVars decls finalConstraint exprVars0 =
    constrainDeclsHelp decls finalConstraint exprVars0 identity

constrainDeclsHelp :
    Can.Decls
    -> Constraint
    -> ExprVarMap
    -> (IO ( Constraint, ExprVarMap ) -> IO ( Constraint, ExprVarMap ))
    -> IO ( Constraint, ExprVarMap )
constrainDeclsHelp decls finalConstraint exprVars cont =
    case decls of
        Can.Declare def rest ->
            constrainDeclsHelp rest finalConstraint exprVars
                ( \io ->
                    IO.andThen
                        (\( constraint, vars1 ) ->
                            Expr.constrainDefWithVars Dict.empty def constraint vars1
                        )
                        io
                        |> cont
                )

        Can.DeclareRec def defs rest ->
            constrainDeclsHelp rest finalConstraint exprVars
                ( \io ->
                    IO.andThen
                        (\( constraint, vars1 ) ->
                            Expr.constrainRecursiveDefsWithVars Dict.empty (def :: defs) constraint vars1
                        )
                        io
                        |> cont
                )

        Can.SaveTheEnvironment ->
            cont (IO.pure ( finalConstraint, exprVars ))
```

For `letPort` / `letCmd` / `letSub` (which wrap constraints in `CLet` for ports/effect managers) you can keep their structure, just thread `ExprVarMap` through unchanged, since they don’t involve new `Can.Expr`s.

### 5.2. Keep a compatibility wrapper

Keep the old `constrain` as:

```elm
constrain : Can.Module -> IO Constraint
constrain modul =
    constrainWithExprVars modul
        |> IO.map Tuple.first
```

Callers that don’t care about TypedCanonical (today, `typeCheck`) can keep using `constrain`. The new typed path will use `constrainWithExprVars`.

---

## 6. Extend the solver to produce per‑expression `Can.Type`

The solver module is `Compiler.Type.Solve`:

```elm
run : Constraint
    -> IO (Result (NE.Nonempty Error.Error) (Dict String Name.Name Can.Annotation))
``` 

We want a richer variant that also returns `Dict Int Can.Type`.

### 6.1. Add `variableToCanTypeIO` helper

In `Compiler.Type.Type` we already have:

- `toAnnotation : Variable -> IO Can.Annotation` (used by `Solve.run` to turn a variable into an annotation)
- `variableToCanType : Variable -> StateT NameState Can.Type` used internally for `toAnnotation`.

Add an IO wrapper:

```elm
variableToCanTypeIO : Variable -> IO Can.Type
variableToCanTypeIO variable =
    getVarNames variable Dict.empty
        |> IO.andThen
            (\userNames ->
                State.runStateT (variableToCanType variable) (makeNameState userNames)
                    |> IO.map Tuple.first
            )
```

This directly mirrors what `toAnnotation` does (but without `Can.Forall` generalization) .

### 6.2. Add `runWithExprVars` in `Compiler.Type.Solve`

```elm
type alias ExprVarMap =
    Dict Int IO.Variable

runWithExprVars :
    Constraint
    -> ExprVarMap
    -> IO
        (Result
            (NE.Nonempty Error.Error)
            { annotations : Dict String Name.Name Can.Annotation
            , exprTypes  : Dict Int Can.Type
            }
        )
runWithExprVars constraint exprVars =
    MVector.replicate 8 []
        |> IO.andThen
            (\pools ->
                solve Dict.empty Type.outermostRank pools emptyState constraint
                    |> IO.andThen
                        (\(State env _ errors) ->
                            case errors of
                                [] ->
                                    -- annotations from env
                                    IO.traverseMap identity compare Type.toAnnotation env
                                        |> IO.andThen
                                            (\annotations ->
                                                -- exprTypes from exprVars
                                                IO.traverseMap identity compare
                                                    (\_ var -> Type.variableToCanTypeIO var)
                                                    exprVars
                                                    |> IO.map
                                                        (\exprTypes ->
                                                            Ok
                                                                { annotations = annotations
                                                                , exprTypes = exprTypes
                                                                }
                                                        )
                                            )

                                e :: es ->
                                    IO.pure (Err (NE.Nonempty e es))
                        )
            )
```

Keep the existing `run` implemented in terms of this:

```elm
run : Constraint -> IO (Result (NE.Nonempty Error.Error) (Dict String Name.Name Can.Annotation))
run constraint =
    runWithExprVars constraint Dict.empty
        |> IO.map (Result.map .annotations)
```

**Intent**:

- Preserve the old API for clients that only care about `annotations`.
- Provide a new API that also returns a fully populated map from `Expr.id` → canonical type.

---

## 7. TypedCanonical AST and builder

Now define the typed AST as a *thin wrapper* around canonical expressions + types.

### 7.1. New module: `Compiler.AST.TypedCanonical`

Create `Compiler/AST/TypedCanonical.elm`:

```elm
module Compiler.AST.TypedCanonical exposing
    ( Module(..), ModuleData
    , Expr, Expr_(..)
    , Def(..), Decls(..)
    , CaseBranch(..), FieldUpdate(..)
    , fromCanonical
    )

import Compiler.AST.Canonical as Can
import Compiler.Reporting.Annotation as A
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Data.Index as Index
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO

type alias Expr =
    A.Located Expr_

type Expr_
    = TypedExpr
        { expr : Can.Expr_
        , tipe : Can.Type
        }

type CaseBranch
    = CaseBranch Can.Pattern Expr

type FieldUpdate
    = FieldUpdate A.Region Expr

type Def
    = Def (A.Located Name) (List Can.Pattern) Expr
    | TypedDef (A.Located Name) Can.FreeVars (List ( Can.Pattern, Can.Type )) Expr Can.Type

type Decls
    = Declare Def Decls
    | DeclareRec Def (List Def) Decls
    | SaveTheEnvironment

type alias ModuleData =
    { name : IO.Canonical
    , exports : Can.Exports
    , docs : Can.Src.Docs
    , decls : Decls
    , unions : Dict String Name Can.Union
    , aliases : Dict String Name Can.Alias
    , binops : Dict String Name Can.Binop
    , effects : Can.Effects
    }

type Module
    = Module ModuleData
```

### 7.2. Implement `fromCanonical`

`fromCanonical` takes:

- A fully canonicalized module (`Can.Module`), and
- `exprTypes : Dict Int Can.Type` from `runWithExprVars`.

And produces a `TypedCanonical.Module`:

```elm
fromCanonical :
    Can.Module
    -> Dict Int Can.Type
    -> Module
fromCanonical (Can.Module canData) exprTypes =
    let
        typedDecls =
            toTypedDecls exprTypes canData.decls
    in
    Module
        { name = canData.name
        , exports = canData.exports
        , docs = canData.docs
        , decls = typedDecls
        , unions = canData.unions
        , aliases = canData.aliases
        , binops = canData.binops
        , effects = canData.effects
        }


toTypedDecls : Dict Int Can.Type -> Can.Decls -> Decls
toTypedDecls exprTypes decls =
    case decls of
        Can.Declare def rest ->
            Declare (toTypedDef exprTypes def)
                (toTypedDecls exprTypes rest)

        Can.DeclareRec def defs rest ->
            DeclareRec
                (toTypedDef exprTypes def)
                (List.map (toTypedDef exprTypes) defs)
                (toTypedDecls exprTypes rest)

        Can.SaveTheEnvironment ->
            SaveTheEnvironment


toTypedDef : Dict Int Can.Type -> Can.Def -> Def
toTypedDef exprTypes def =
    case def of
        Can.Def name args body ->
            Def name args (toTypedExpr exprTypes body)

        Can.TypedDef name freeVars typedArgs body resultType ->
            TypedDef name freeVars typedArgs (toTypedExpr exprTypes body) resultType


toTypedExpr : Dict Int Can.Type -> Can.Expr -> Expr
toTypedExpr exprTypes (A.At region info) =
    let
        tipe =
            case Dict.get identity info.id exprTypes of
                Just t ->
                    t

                Nothing ->
                    Debug.crash ("Missing type for expr id " ++ String.fromInt info.id)
    in
    A.At region (TypedExpr { expr = info.node, tipe = tipe })
```

**Intent**:

- Keep the `Can.Expr_` tree as‑is in `expr`, but pair it with the final `Can.Type`.
- Use the embedded `info.id` from canonicalization as the key into `exprTypes`, so we don’t rely on any structural indexing pass.

---

## 8. Expose typed typechecking in `Compiler.Compile`

`Compiler.Compile` currently defines `typeCheck` as:

```elm
typeCheck : Src.Module -> Can.Module -> Result E.Error (Dict String Name Can.Annotation)
typeCheck modul canonical =
    case Type.constrain canonical
        |> TypeCheck.andThen Type.run
        |> TypeCheck.unsafePerformIO of
        Ok annotations ->
            Ok annotations

        Err errors ->
            Err (E.BadTypes (Localizer.fromModule modul) errors)
``` 

Add a new richer API:

```elm
import Compiler.AST.TypedCanonical as TCan
import Compiler.Type.Constrain.Module as Constrain
import Compiler.Type.Solve as Solve

typeCheckTyped :
    Src.Module
    -> Can.Module
    -> Result E.Error
        { annotations : Dict String Name.Name Can.Annotation
        , typedCanonical : TCan.Module
        }
typeCheckTyped modul canonical =
    let
        ioResult =
            Constrain.constrainWithExprVars canonical
                |> TypeCheck.andThen
                    (\( constraint, exprVars ) ->
                        Solve.runWithExprVars constraint exprVars
                    )
                |> TypeCheck.unsafePerformIO
    in
    case ioResult of
        Err errors ->
            Err (E.BadTypes (Localizer.fromModule modul) errors)

        Ok { annotations, exprTypes } ->
            Ok
                { annotations = annotations
                , typedCanonical = TCan.fromCanonical canonical exprTypes
                }
```

Then reimplement the original `typeCheck` in terms of this:

```elm
typeCheck modul canonical =
    Result.map .annotations (typeCheckTyped modul canonical)
```

Every existing caller that only cares about annotations continues to work, and you now have a richer artifact available for future phases.

You can also extend `TypedArtifactsData` if you want to persist `TypedCanonical.Module` alongside `Can.Module` and typed optimized graphs.

---

## 9. Summary of changes by module

**AST & canonicalization**

- `Compiler.AST.Canonical`:
    - Change `Expr` to `A.Located ExprInfo` with `ExprInfo = { id : Int, node : Expr_ }`.
    - Add `exprId` and `exprNode` helpers.

- `Compiler.Canonicalize.Expression`:
    - Introduce `IdState` and `canonicalizeWithIds`.
    - Change public `canonicalize` to call `canonicalizeWithIds` and drop the final `IdState`.
    - Ensure all constructed `Can.Expr` nodes get a unique ID.

- Any other canonicalization code that builds `Can.Expr` directly:
    - Route through helper that assigns IDs.

**Constraint generation**

- `Compiler.Type.Constrain.Expression`:
    - Define `ExprVarMap = Dict Int IO.Variable`.
    - Add `constrainWithVars` and `constrainNode` that:
        - allocate a `Variable` per `Expr.id` (`Type.mkFlexVar`),
        - build the usual constraints, and
        - record `id -> Variable` in the map.
    - Add `constrainDefWithVars`, `constrainRecursiveDefsWithVars` that thread `ExprVarMap` instead of only `Constraint`.

- `Compiler.Type.Constrain.Module`:
    - Add `constrainWithExprVars : Can.Module -> IO (Constraint, ExprVarMap)` and `constrainDeclsWithVars`.
    - Implement old `constrain` in terms of `constrainWithExprVars` by discarding the map.

**Solver & type conversion**

- `Compiler.Type.Type`:
    - Add `variableToCanTypeIO : Variable -> IO Can.Type`, wrapping existing `variableToCanType` logic with `State.runStateT`, as already done in `toAnnotation`.

- `Compiler.Type.Solve`:
    - Add `runWithExprVars : Constraint -> ExprVarMap -> IO (Result _ { annotations; exprTypes })`.
    - Keep `run` delegating to this with an empty `ExprVarMap`.

**Typed canonical view**

- New `Compiler.AST.TypedCanonical`:
    - Define `Expr = A.Located (TypedExpr { expr : Can.Expr_, tipe : Can.Type })`, `Def`, `Decls`, `ModuleData`, `Module`.
    - Implement `fromCanonical : Can.Module -> Dict Int Can.Type -> Module` to zip `exprTypes` onto the canonical tree using `info.id` on each `Can.Expr`.

**Pipeline / API**

- `Compiler.Compile`:
    - Add `typeCheckTyped` that uses `Constrain.constrainWithExprVars` + `Solve.runWithExprVars` + `TypedCanonical.fromCanonical`.
    - Re‑define `typeCheck` in terms of `typeCheckTyped` (`Result.map .annotations`).

---

This plan gives you a properly typed canonical AST where **every expression knows its final `Can.Type`**, derived directly from the one and only HM inference engine, and keyed by IDs that live on `Can.Expr` itself. Later passes (TypedOptimized, monomorphization, MLIR codegen) can then be simplified to *preserve* or *refine* types rather than re‑deriving them.

