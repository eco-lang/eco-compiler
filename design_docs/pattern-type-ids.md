Below is a concrete design that:

- assigns **one unified ID space** over both canonical expressions and patterns, and
- builds **one `Dict Int Int Can.Type`** mapping those IDs to types during type checking.

I’ll break it into self-contained steps an engineer can implement.

---

## 1. Goals & invariants

We want:

1. Every **canonical expression** and **canonical pattern** node has a unique `Int` ID, unique across the whole module.
2. During type checking we build a single map:

   ```elm
   type alias NodeTypeMap =
       Dict Int Int Can.Type
   ```

   where each key is the ID of either a `Can.Expr` or `Can.Pattern`, and the value is its inferred `Can.Type`.

3. The existing, non-typed pipeline (`Type.constrain` + `Solve.run`) remains available and **unchanged**.
4. The new typed pipeline continues to go through `constrain + solve` as it does now, just with extra bookkeeping.

---

## 2. Canonical AST: add IDs to patterns and unify ID allocation

### 2.1. Extend canonical patterns with IDs

In `Compiler/AST/Canonical.elm` we already have `Expr` with `ExprInfo` and `Expr_` plus pattern types.

Currently:

```elm
-- ====== Patterns ======

type alias Pattern =
    A.Located Pattern_

type Pattern_
    = PAnything
    | PVar Name
    | PRecord (List Name)
    | PAlias Pattern Name
    | PUnit
    | PTuple Pattern Pattern (List Pattern)
    | PList (List Pattern)
    | PCons Pattern Pattern
    | PBool Union Bool
    | PChr String
    | PStr String Bool
    | PInt Int
    | PCtor { home : IO.Canonical, type_ : Name, union : Union, name : Name, index : Index.ZeroBased, args : List PatternCtorArg }
```

Change to:

```elm
-- ====== Patterns ======

{-| A pattern with source location and unique ID. -}
type alias Pattern =
    A.Located PatternInfo

type alias PatternInfo =
    { id : Int
    , node : Pattern_
    }

type Pattern_
    = PAnything
    | PVar Name
    | PRecord (List Name)
    | PAlias Pattern Name
    | PUnit
    | PTuple Pattern Pattern (List Pattern)
    | PList (List Pattern)
    | PCons Pattern Pattern
    | PBool Union Bool
    | PChr String
    | PStr String Bool
    | PInt Int
    | PCtor
        { home : IO.Canonical
        , type_ : Name
        , union : Union
        , name : Name
        , index : Index.ZeroBased
        , args : List PatternCtorArg
        }
```

Add helpers analogous to `exprId`/`exprNode`:

```elm
patternId : Pattern -> Int
patternId (A.At _ info) =
    info.id

patternNode : Pattern -> Pattern_
patternNode (A.At _ info) =
    info.node
```

**Intent:** in later phases, we can easily look up a pattern’s ID (for node→type mapping) without touching the internal structure.

### 2.2. Update pattern serialization

`patternEncoder` / `patternDecoder` currently serialize `Pattern_` directly:

```elm
patternEncoder : Pattern -> Bytes.Encode.Encoder
patternEncoder =
    A.locatedEncoder pattern_Encoder

patternDecoder : Bytes.Decode.Decoder Pattern
patternDecoder =
    A.locatedDecoder pattern_Decoder
```

`A.locatedEncoder` / `A.locatedDecoder` expect a payload type; we’ve changed that payload from `Pattern_` to `PatternInfo`.

Update to:

```elm
patternEncoder : Pattern -> Bytes.Encode.Encoder
patternEncoder =
    A.locatedEncoder patternInfoEncoder

patternDecoder : Bytes.Decode.Decoder Pattern
patternDecoder =
    A.locatedDecoder patternInfoDecoder

patternInfoEncoder : PatternInfo -> Bytes.Encode.Encoder
patternInfoEncoder info =
    Bytes.Encode.sequence
        [ BE.int info.id
        , pattern_Encoder info.node
        ]

patternInfoDecoder : Bytes.Decode.Decoder PatternInfo
patternInfoDecoder =
    Bytes.Decode.map2 PatternInfo
        BD.int
        pattern_Decoder
```

`pattern_Encoder` / `pattern_Decoder` keep their existing structure over `Pattern_`.

### 2.3. Shared ID state for canonicalization

Right now, expression canonicalization defines its own `IdState` and `makeExpr`:

```elm
type alias IdState =
    { nextId : Int }

initialIdState : IdState
initialIdState = { nextId = 0 }

allocId : IdState -> ( Int, IdState )
allocId state =
    ( state.nextId, { nextId = state.nextId + 1 } )

makeExpr : A.Region -> IdState -> Can.Expr_ -> ( Can.Expr, IdState )
makeExpr region state node =
    let
        ( id, newState ) =
            allocId state
    in
    ( A.At region { id = id, node = node }, newState )
```

Extract this into a small shared module:

**New module:** `Compiler/Canonicalize/Ids.elm`

```elm
module Compiler.Canonicalize.Ids exposing (IdState, initialIdState, allocId)

import Compiler.Reporting.Annotation as A

type alias IdState =
    { nextId : Int }

initialIdState : IdState
initialIdState =
    { nextId = 0 }

allocId : IdState -> ( Int, IdState )
allocId state =
    ( state.nextId, { nextId = state.nextId + 1 } )
```

- In `Compiler.Canonicalize.Expression`, remove the local `IdState`, `initialIdState`, `allocId` definitions and **import** them from `Compiler.Canonicalize.Ids`. Keep `makeExpr` as is but using the imported `allocId`.

### 2.4. Canonicalize patterns with IDs, using same `IdState`

In `Compiler/Canonicalize/Pattern.elm` we currently canonicalize to `Can.Pattern` as `A.At region pattern_`.

We need to:

1. Import `Compiler.Canonicalize.Ids` (`IdState`, `allocId`).
2. Add a helper:

   ```elm
   makePattern : A.Region -> IdState -> Can.Pattern_ -> ( Can.Pattern, IdState )
   makePattern region state node =
       let
           ( id, newState ) =
               Ids.allocId state
       in
       ( A.At region { id = id, node = node }, newState )
   ```

3. Change the main `canonicalize` to an ID-aware version.

Current shape (simplified):

```elm
canonicalize :
    SyntaxVersion
    -> Env.Env
    -> Src.Pattern
    -> PResult DupsDict w Can.Pattern
canonicalize syntaxVersion env (A.At region srcPattern) =
    case srcPattern of
        Src.PVar name ->
            logVar name region (Can.PVar name)
                |> ReportingResult.map (A.At region)

        Src.PRecord ... ->
            ... |> ReportingResult.map (A.At region)

        Src.PUnit _ ->
            ReportingResult.ok Can.PUnit
                |> ReportingResult.map (A.At region)

        -- etc...
```

Refactor to:

```elm
canonicalizeWithIds :
    SyntaxVersion
    -> Env.Env
    -> IdState
    -> Src.Pattern
    -> PResult DupsDict w ( Can.Pattern, IdState )
canonicalizeWithIds syntaxVersion env state0 (A.At region srcPattern) =
    case srcPattern of
        Src.PVar name ->
            logVar name region (Can.PVar name)
                |> ReportingResult.map
                    (\pattern_ -> makePattern region state0 pattern_)

        Src.PRecord ( _, c2Fields ) ->
            let
                fields : List (A.Located Name.Name)
                fields =
                    List.map Src.c2Value c2Fields
            in
            logFields fields (Can.PRecord (List.map A.toValue fields))
                |> ReportingResult.map
                    (\pattern_ -> makePattern region state0 pattern_)

        Src.PUnit _ ->
            ReportingResult.ok Can.PUnit
                |> ReportingResult.map
                    (\pattern_ -> makePattern region state0 pattern_)

        Src.PTuple ( _, a ) ( _, b ) cs ->
            canonicalizeWithIds syntaxVersion env state0 a
                |> ReportingResult.andThen
                    (\( canA, state1 ) ->
                        canonicalizeWithIds syntaxVersion env state1 b
                            |> ReportingResult.andThen
                                (\( canB, state2 ) ->
                                    canonicalizeTuple syntaxVersion region env (List.map Src.c2Value cs)
                                        |> ReportingResult.map
                                            (\canCs ->
                                                makePattern region state2 (Can.PTuple canA canB canCs)
                                            )
                                )
                    )

        -- similar for PCtor, PList, PCons, PAlias, literals...

```

Add a wrapper preserving the old API (for callers that don’t care about IDs):

```elm
canonicalize :
    SyntaxVersion
    -> Env.Env
    -> Src.Pattern
    -> PResult DupsDict w Can.Pattern
canonicalize syntaxVersion env srcPattern =
    canonicalizeWithIds syntaxVersion env Ids.initialIdState srcPattern
        |> ReportingResult.map Tuple.first
```

**Intent:** Both expressions and patterns now share the same `IdState` allocator, making IDs unique across *all* canonical nodes when driven from a single top-level canonicalization pass.

### 2.5. Wire `IdState` through expression canonicalization

`Compiler.Canonicalize.Expression` already threads an `IdState` for expressions:

```elm
canonicalizeWithIds : SyntaxVersion -> Env.Env -> IdState -> Src.Expr -> ... ( Can.Expr, IdState )

canonicalizeNode syntaxVersion env state0 region expression =
    case expression of
        Src.Call func args -> ...
        Src.Lambda patterns body -> ...
        Src.Case expr branches -> ...
```

Wherever expressions canonicalize **patterns**, switch to the `Pattern.canonicalizeWithIds` that threads `IdState`:

- Lambda arguments: `Src.Lambda patterns body`

  ```elm
  Src.Lambda argPatterns body ->
      traversePatternsWithIds syntaxVersion env state0 argPatterns
          |> ReportingResult.andThen
              (\( canPatterns, state1 ) ->
                  canonicalizeWithIds syntaxVersion env state1 body
                      |> ReportingResult.map
                          (\( canBody, state2 ) ->
                              makeExpr region state2 (Can.Lambda canPatterns canBody)
                          )
              )
  ```

  where `traversePatternsWithIds` is a helper similar to `traverseWithIds` for expressions, using `Pattern.canonicalizeWithIds`.

- Case branches: `Src.Case expr branches` → each branch pattern should be canonicalized via `canonicalizeWithIds` and share the same evolving `IdState`.

**Key point:** At the *module level* (in the canonicalize-module pass, not shown here) you must start once with `Ids.initialIdState` and thread it through *all* expression and pattern canonicalization, so there is a single global counter.

---

## 3. Shared node-ID → solver-variable map

We now want a single map from node IDs (exprs + patterns) to solver variables.

### 3.1. New shared module for node ID tracking

Right now, expression tracking lives in `Compiler.Type.Constrain.Expression` as:

```elm
type alias ExprVarMap =
    Dict Int Int IO.Variable

type alias ExprIdState =
    { mapping : ExprVarMap }

emptyExprIdState : ExprIdState
emptyExprIdState = { mapping = Dict.empty }
```

Refactor this into a shared module:

**New module:** `Compiler/Type/Constrain/NodeIds.elm`

```elm
module Compiler.Type.Constrain.NodeIds exposing
    ( NodeVarMap
    , NodeIdState
    , emptyNodeIdState
    , recordNodeVar
    )

import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO

type alias NodeVarMap =
    Dict Int Int IO.Variable

type alias NodeIdState =
    { mapping : NodeVarMap }

emptyNodeIdState : NodeIdState
emptyNodeIdState =
    { mapping = Dict.empty }

recordNodeVar : Int -> IO.Variable -> NodeIdState -> NodeIdState
recordNodeVar id var state =
    if id >= 0 then
        { mapping = Dict.insert identity id var state.mapping }
    else
        -- negative IDs for placeholders (see makeExprPlaceholder)
        state
```

### 3.2. Refactor expression-side to use `NodeIdState`

In `Compiler.Type.Constrain.Expression`:

- Replace the local `ExprVarMap`, `ExprIdState`, `emptyExprIdState` with imports from `NodeIds`.
- Adjust type signatures:

  ```elm
  -- before
  type alias ExprVarMap = Dict Int Int IO.Variable
  type alias ExprIdState = { mapping : ExprVarMap }

  constrainWithIds :
      RigidTypeVar
      -> Can.Expr
      -> E.Expected Type
      -> ExprIdState
      -> IO ( Constraint, ExprIdState )
  ```

  becomes:

  ```elm
  import Compiler.Type.Constrain.NodeIds as NodeIds

  constrainWithIds :
      RigidTypeVar
      -> Can.Expr
      -> E.Expected Type
      -> NodeIds.NodeIdState
      -> IO ( Constraint, NodeIds.NodeIdState )
  ```

- Inside `constrainWithIds`, keep the behavior but use `NodeIds.recordNodeVar`:

  ```elm
  constrainWithIds rtv ((A.At region exprInfo) as expr) expected state =
      Type.mkFlexVar
          |> IO.andThen
              (\exprVar ->
                  let
                      exprId = exprInfo.id

                      newState =
                          NodeIds.recordNodeVar exprId exprVar state

                      exprType = VarN exprVar
                  in
                  constrain rtv expr expected
                      |> IO.map
                          (\con ->
                              ( CAnd [ con, CEqual region Record exprType expected ]
                              , newState
                              )
                          )
              )
  ```

- Similarly, update `constrainDefWithIds`, `constrainRecursiveDefsWithIds`, etc. to use `NodeIdState` instead of `ExprIdState`.

### 3.3. Add ID tracking for patterns

We now want to record a variable for each **pattern node ID**, representing the type of the value matched by that pattern.

We will:

- Add a *new* function `addWithIds` in `Compiler.Type.Constrain.Pattern`.
- Leave existing `add` unchanged, to preserve old `constrain` semantics.
- For the typed path, use `addWithIds` instead of `add`.

#### 3.3.1. Extend `Pattern.add` API

`Compiler.Type.Constrain.Pattern` currently has:

```elm
type State
    = State Header (List IO.Variable) (List Type.Constraint)

add : Can.Pattern -> E.PExpected Type -> State -> IO State
add (A.At region pattern) expectation state =
    case pattern of
        Can.PAnything -> ...
        Can.PVar name -> ...
        Can.PAlias realPattern name -> ...
        ...
```

Add imports:

```elm
import Compiler.Type.Constrain.NodeIds as NodeIds
```

Define a new function:

```elm
addWithIds :
    Can.Pattern
    -> E.PExpected Type
    -> State
    -> NodeIds.NodeIdState
    -> IO ( State, NodeIds.NodeIdState )
addWithIds ((A.At region info) as pattern) expectation state nodeState0 =
    let
        tipe : Type
        tipe =
            getType expectation
    in
    -- First, associate this pattern node's ID with a dedicated variable
    Type.mkFlexVar
        |> IO.andThen
            (\patVar ->
                let
                    patType = Type.VarN patVar

                    eqCon : Type.Constraint
                    eqCon =
                        Type.CEqual region E.PPattern patType tipe

                    -- extend the pattern state with this new variable + constraint
                    (State headers vars revCons) =
                        state

                    stateWithPatVar =
                        State headers (patVar :: vars) (eqCon :: revCons)

                    -- record ID → variable mapping
                    nodeState1 =
                        NodeIds.recordNodeVar info.id patVar nodeState0
                in
                -- Now generate all the usual pattern constraints over `stateWithPatVar`
                addHelpWithIds region info.node expectation stateWithPatVar nodeState1
            )
```

Here `E.PPattern` is a new context tag you add to `Compiler.Reporting.Error.Type` (alongside existing pattern contexts like `PList`, `PTuple`, etc.) so `CEqual` has a meaningful origin.

Now implement `addHelpWithIds` mirroring the existing `add` logic but threading `NodeIdState`:

```elm
addHelpWithIds :
    A.Region
    -> Can.Pattern_
    -> E.PExpected Type
    -> State
    -> NodeIds.NodeIdState
    -> IO ( State, NodeIds.NodeIdState )
addHelpWithIds region pattern expectation state nodeState =
    case pattern of
        Can.PAnything ->
            IO.pure ( state, nodeState )

        Can.PVar name ->
            -- same behavior as old add, plus we already added equality above
            IO.pure ( addToHeaders region name expectation state, nodeState )

        Can.PAlias realPattern name ->
            let
                state1 =
                    addToHeaders region name expectation state
            in
            addWithIds realPattern expectation state1 nodeState

        Can.PUnit ->
            -- identical to old PUnit case, with NodeIdState threaded
            let
                (State headers vars revCons) =
                    state

                unitCon : Type.Constraint
                unitCon =
                    Type.CPattern region E.PUnit Type.UnitN expectation
            in
            IO.pure ( State headers vars (unitCon :: revCons), nodeState )

        Can.PTuple a b cs ->
            -- reuse existing helper but call into addWithIds for children
            addTupleWithIds region a b cs expectation state nodeState

        Can.PCtor { home, type_, union, name, args } ->
            addCtorWithIds region home type_ union.vars name args expectation state nodeState

        Can.PList patterns ->
            -- mirror existing PList, but use addWithIds for each element
            Type.mkFlexVar
                |> IO.andThen
                    (\entryVar ->
                        let
                            entryType =
                                Type.VarN entryVar

                            listType =
                                Type.AppN ModuleName.list Name.list [ entryType ]
                        in
                        IO.foldM
                            (\s ( index, pat ) ->
                                let
                                    expectationEntry =
                                        E.PFromContext region (E.PListEntry index) entryType
                                in
                                case s of
                                    ( st, ns ) ->
                                        addWithIds pat expectationEntry st ns
                            )
                            ( state, nodeState )
                            (Index.indexedMap Tuple.pair patterns)
                            |> IO.map
                                (\( State headers vars revCons, ns ) ->
                                    let
                                        listCon =
                                            Type.CPattern region E.PList listType expectation
                                    in
                                    ( State headers (entryVar :: vars) (listCon :: revCons)
                                    , ns
                                    )
                                )
                    )

        -- similarly for PCons, PRecord, PInt/PStr/PChr/PBool (just threading ns)

```

Where `addTupleWithIds` / `addCtorWithIds` reuse the logic of `addTuple` / `addCtor` but call `addWithIds` (not `add`) on subpatterns. You can follow the same mechanical translation as above for those helpers.

**Intent:**

- `addWithIds` ensures **every pattern node** has:
    - its own fresh solver variable `patVar`,
    - a `CEqual` equating `patVar` with the expected type at that node, and
    - an entry in `NodeIdState.mapping` from `patternId` to `patVar`.
- Structural constraints and headers remain exactly as the existing `add` produces; we’ve just layered on extra equalities and a side-map.

We keep the original `add` untouched so **existing code paths continue to behave exactly as before**.

---

## 4. Thread `NodeIdState` through constraint generation

### 4.1. Args helpers (function patterns)

In `Compiler.Type.Constrain.Expression`, we currently have:

```elm
constrainArgs : List Can.Pattern -> IO Args
constrainArgs args =
    argsHelp args Pattern.emptyState

argsHelp : List Can.Pattern -> Pattern.State -> IO Args
argsHelp args state =
    case args of
        [] ->
            Type.mkFlexVar
                |> IO.map (\resultVar -> ...)

        pattern :: otherArgs ->
            Type.mkFlexVar
                |> IO.andThen
                    (\argVar ->
                        let
                            argType = VarN argVar
                            expectation = E.PNoExpectation argType
                        in
                        Pattern.add pattern expectation state
                            |> IO.andThen (argsHelp otherArgs)
                            |> IO.map ...
                    )
```

Add an ID-aware variant:

```elm
constrainArgsWithIds :
    List Can.Pattern
    -> NodeIds.NodeIdState
    -> IO ( Args, NodeIds.NodeIdState )
constrainArgsWithIds args nodeState0 =
    argsHelpWithIds args Pattern.emptyState nodeState0


argsHelpWithIds :
    List Can.Pattern
    -> Pattern.State
    -> NodeIds.NodeIdState
    -> IO ( Args, NodeIds.NodeIdState )
argsHelpWithIds args state nodeState =
    case args of
        [] ->
            Type.mkFlexVar
                |> IO.map
                    (\resultVar ->
                        let
                            resultType = VarN resultVar
                            argsRecord =
                                makeArgs [ resultVar ] resultType resultType state
                        in
                        ( argsRecord, nodeState )
                    )

        pattern :: otherArgs ->
            Type.mkFlexVar
                |> IO.andThen
                    (\argVar ->
                        let
                            argType = VarN argVar
                            expectation = E.PNoExpectation argType
                        in
                        Pattern.addWithIds pattern expectation state nodeState
                            |> IO.andThen
                                (\( newState, nodeState1 ) ->
                                    argsHelpWithIds otherArgs newState nodeState1
                                        |> IO.map
                                            (\( Args props, nodeState2 ) ->
                                                -- same as old argsHelp's map, but return nodeState2
                                                ( makeArgs
                                                    (argVar :: props.vars)
                                                    (FunN argType props.tipe)
                                                    props.result
                                                    props.state
                                                , nodeState2
                                                )
                                            )
                                )
                    )
```

- Keep existing `constrainArgs`/`argsHelp` unchanged for the old path.

- For typed path (`constrainDefWithIds`, `constrainRecursiveDefsWithIds`), switch to `constrainArgsWithIds`.

Similarly, for annotated args, update `constrainTypedArgs` and `typedArgsHelp` to have `... -> Pattern.State -> NodeIds.NodeIdState -> IO (TypedArgs, NodeIds.NodeIdState)` and use `Pattern.addWithIds` when assigning constraints to patterns.

### 4.2. Use pattern ID-tracking in ID-aware def/rec-def constraint functions

In `Compiler.Type.Constrain.Expression`, `constrainDefWithIds` currently does:

```elm
constrainDefWithIds rtv def bodyCon state =
    case def of
        Can.Def (A.At region name) args expr ->
            constrainArgs args
                |> IO.andThen
                    (\(Args props) ->
                        let
                            (Pattern.State headers pvars revCons) =
                                props.state
                        in
                        constrainWithIds rtv expr ... state
                            |> IO.map
                                (\( exprCon, newState ) ->
                                    ( CLet [] props.vars ...
                                        (CLet [] pvars headers (CAnd (List.reverse revCons)) exprCon)
                                        bodyCon
                                    , newState
                                    )
                                )
                    )
        ...
```

Change this ID-aware version to use the new arg helper and thread `NodeIdState`:

```elm
constrainDefWithIds :
    RigidTypeVar
    -> Can.Def
    -> Constraint
    -> NodeIds.NodeIdState
    -> IO ( Constraint, NodeIds.NodeIdState )
constrainDefWithIds rtv def bodyCon nodeState0 =
    case def of
        Can.Def (A.At region name) args expr ->
            constrainArgsWithIds args nodeState0
                |> IO.andThen
                    (\( Args props, nodeState1 ) ->
                        let
                            (Pattern.State headers pvars revCons) =
                                props.state
                        in
                        constrainWithIds rtv expr (NoExpectation props.result) nodeState1
                            |> IO.map
                                (\( exprCon, nodeState2 ) ->
                                    ( CLet []
                                        props.vars
                                        (Dict.singleton identity name (A.At region props.tipe))
                                        (CLet []
                                            pvars
                                            headers
                                            (CAnd (List.reverse revCons))
                                            exprCon
                                        )
                                        bodyCon
                                    , nodeState2
                                    )
                                )
                    )

        -- similarly update the TypedDef and recursive-def helpers to thread nodeState
```

Do the same for `recDefsHelpWithIds` / `constrainRecursiveDefsWithIds`.

### 4.3. Module-level entry point: `constrainWithIds`

In `Compiler.Type.Constrain.Module` we already have:

```elm
constrainWithExprVars : Can.Module -> IO ( Constraint, Expr.ExprVarMap )
```

Refactor it to use `NodeIds.NodeIdState` and rename/comment to the more general notion:

```elm
constrainWithIds : Can.Module -> IO ( Constraint, NodeIds.NodeVarMap )
constrainWithIds (Can.Module canData) =
    let
        initialState : NodeIds.NodeIdState
        initialState =
            NodeIds.emptyNodeIdState
    in
    case canData.effects of
        Can.NoEffects ->
            constrainDeclsWithVars canData.decls CSaveTheEnvironment initialState
                |> IO.map (\( c, s ) -> ( c, s.mapping ))

        -- same pattern for Ports and Manager cases but using initialState
```

Where `constrainDeclsWithVars` and `letPortWithVars` etc. now work with `NodeIdState` instead of `Expr.ExprIdState`, and call `Expr.constrainDefWithIds` / `Expr.constrainRecursiveDefsWithIds`.

**Intent:** After this, `constrainWithIds` returns a constraint tree and a **single** `NodeVarMap` that contains variables for both expression nodes and pattern nodes (since both `constrainWithIds` and `Pattern.addWithIds` populate it).

---

## 5. Solver: from `ExprVars` to unified node types

### 5.1. Generalize `runWithExprVars` to `runWithIds`

`Compiler.Type.Solve` currently exposes:

```elm
runWithExprVars :
    Constraint
    -> Dict Int Int Variable
    -> IO
        (Result
            (NE.Nonempty Error.Error)
            { annotations : Dict String Name.Name Can.Annotation
            , exprTypes : Dict Int Int Can.Type
            }
        )
```

The types are already generic enough; you can simply interpret the `Dict Int Int Variable` argument as a **node var map** and the `exprTypes` as **node types**.

Option A (minimal change): keep the API name but update docstrings and internal names:

- Rename the local binding from `exprVars` to `nodeVars`.
- Rename result field from `exprTypes` to `nodeTypes` (this is a breaking change to callers; if you want to avoid that, keep the name but document that it now includes both expressions and patterns).

For clarity, I’d suggest:

```elm
runWithIds :
    Constraint
    -> Dict Int Int Variable  -- NodeVarMap
    -> IO
        (Result
            (NE.Nonempty Error.Error)
            { annotations : Dict String Name.Name Can.Annotation
            , nodeTypes  : Dict Int Int Can.Type
            }
        )
runWithIds constraint nodeVars =
    MVector.replicate 8 []
        |> IO.andThen
            (\pools ->
                solve Dict.empty Type.outermostRank pools emptyState constraint
                    |> IO.andThen
                        (\(State env _ errors) ->
                            case errors of
                                [] ->
                                    IO.traverseMap identity compare Type.toAnnotation env
                                        |> IO.andThen
                                            (\annotations ->
                                                IO.traverseMap identity compare Type.toCanType nodeVars
                                                    |> IO.map
                                                        (\nodeTypes ->
                                                            Ok
                                                                { annotations = annotations
                                                                , nodeTypes = nodeTypes
                                                                }
                                                        )
                                            )

                                e :: es ->
                                    IO.pure (Err (NE.Nonempty e es))
                        )
            )
```

Then define `runWithExprVars` as a compatibility wrapper if needed, mapping `.nodeTypes` to `.exprTypes`.

**Intent:** No change in solving behavior; we simply convert more variables (including pattern ones) into canonical types and return them in a single map.

---

## 6. Typed pipeline integration

### 6.1. `typeCheckTyped` now uses `constrainWithIds` + `runWithIds`

In `Compile.elm`, `typeCheckTyped` looks like:

```elm
typeCheckTyped modul canonical =
    let
        ioResult =
            Type.constrainWithExprVars canonical
                |> TypeCheck.andThen
                    (\( constraint, exprVars ) ->
                        Type.runWithExprVars constraint exprVars
                    )
                |> TypeCheck.unsafePerformIO
    in
    case ioResult of
        Err errors -> ...
        Ok { annotations, exprTypes } ->
            let
                typedCanonical =
                    TCan.fromCanonical canonical exprTypes
            in
            Ok { annotations = annotations, typedCanonical = typedCanonical }
```

Change to:

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
            Err (E.BadTypes (Localizer.fromModule modul) errors)

        Ok { annotations, nodeTypes } ->
            let
                typedCanonical =
                    TCan.fromCanonical canonical nodeTypes
            in
            Ok { annotations = annotations, typedCanonical = typedCanonical }
```

### 6.2. TypedCanonical: still only consumes expression IDs (for now)

`Compiler.AST.TypedCanonical.fromCanonical` currently takes `Dict Int Int Can.Type` labeled as `exprTypes` and only uses IDs from `Can.Expr` to build typed expressions:

```elm
fromCanonical : Can.Module -> Dict Int Int Can.Type -> Module
fromCanonical (Can.Module canData) exprTypes =
    let
        typedDecls =
            toTypedDecls exprTypes canData.decls
    in
    Module { decls = typedDecls, ... }

toTypedExpr : Dict Int Int Can.Type -> Can.Expr -> Expr
toTypedExpr exprTypes ((A.At region info) as expr) =
    let
        tipe =
            case Dict.get identity info.id exprTypes of
                Just t -> t
                Nothing ->
                    if info.id < 0 then
                        Can.TVar "?"
                    else
                        crash "Missing type for expression id ..."
    in
    A.At region (TypedExpr { expr = Can.exprNode expr, tipe = tipe })
```

You can simply:

- Rename the argument to `nodeTypes` and keep passing it where you expect expression IDs. The dictionary now has more keys (pattern IDs) but you’ll only look up expression IDs; nothing breaks.

Later, if you want TypedCanonical to also include typed patterns, you can:

- Define a `TypedPattern` type and build it using `patternId` and the same `nodeTypes` map.

---

## 7. Summary of concrete code changes

1. **Canonical AST (`Compiler/AST/Canonical.elm`)**
    - Add `PatternInfo`, `patternId`, `patternNode`.
    - Update `Pattern` to `A.Located PatternInfo`.
    - Update `patternEncoder`/`patternDecoder` to encode/decode ID + `Pattern_`.

2. **Canonicalization**
    - New `Compiler.Canonicalize.Ids` with `IdState`, `initialIdState`, `allocId`.
    - In `Compiler.Canonicalize.Expression`, import that module; keep `makeExpr`.
    - In `Compiler.Canonicalize.Pattern`:
        - Import `Ids`.
        - Add `makePattern`.
        - Introduce `canonicalizeWithIds` returning `(Can.Pattern, IdState)`.
        - Change expression canonicalizer to call `Pattern.canonicalizeWithIds` whenever patterns are produced (lambda args, case branches, etc.).

3. **Node ID tracking (`Compiler.Type.Constrain.NodeIds`)**
    - New module with `NodeVarMap`, `NodeIdState`, `emptyNodeIdState`, `recordNodeVar`.

4. **Expression constraint generation (`Compiler.Type.Constrain.Expression`)**
    - Replace local `ExprVarMap`/`ExprIdState` with `NodeIds.NodeVarMap` / `NodeIdState`.
    - `constrainWithIds` now updates `NodeIdState` via `NodeIds.recordNodeVar`.
    - Add `constrainArgsWithIds` / `argsHelpWithIds` and ID-aware versions of `constrainTypedArgs` / `typedArgsHelp`, calling `Pattern.addWithIds`.
    - Update `constrainDefWithIds` / `constrainRecursiveDefsWithIds` to use these and to thread `NodeIdState` through.

5. **Pattern constraint generation (`Compiler.Type.Constrain.Pattern`)**
    - Import `NodeIds`.
    - Add `addWithIds : Can.Pattern -> PExpected Type -> State -> NodeIdState -> IO (State, NodeIdState)`.
    - Implement `addWithIds` as:
        - allocate a fresh var per pattern node (`patVar`),
        - add `CEqual` between `VarN patVar` and `getType expectation`,
        - call `addHelpWithIds` which mirrors `add` but recurses via `addWithIds`.
    - Keep existing `add` unchanged for the legacy path.

6. **Module constraint entry (`Compiler.Type.Constrain.Module`)**
    - Replace `constrainWithExprVars` with `constrainWithIds`, using `NodeIds.emptyNodeIdState` and returning `NodeVarMap`.

7. **Solver (`Compiler.Type.Solve`)**
    - Generalize `runWithExprVars` to `runWithIds`, taking `NodeVarMap` and returning `{ annotations, nodeTypes }` by calling `Type.toCanType` on each variable.
    - Optionally keep `runWithExprVars` as a thin wrapper for backward compatibility.

8. **Typed pipeline (`Compile.typeCheckTyped`)**
    - Switch from `Type.constrainWithExprVars` + `Type.runWithExprVars` to `Type.constrainWithIds` + `Type.runWithIds`.
    - Pass the resulting `nodeTypes` into `TypedCanonical.fromCanonical`.

9. **TypedCanonical (`Compiler.AST.TypedCanonical`)**
    - Treat the input `Dict Int Int Can.Type` as a unified node-type map; continue using expression IDs only in `toTypedExpr` for now.

---

With these changes:

- All canonical expressions and patterns share a **single ID space** via `IdState`.
- Constraint generation tracks a **single `NodeVarMap`** mapping those IDs to solver variables.
- The solver converts that to a **single `Dict Int Int Can.Type`** that can be used by any later phase to attach types to arbitrary AST nodes (expressions now; patterns when you’re ready).

