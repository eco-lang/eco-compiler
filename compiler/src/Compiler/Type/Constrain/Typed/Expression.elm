module Compiler.Type.Constrain.Typed.Expression exposing (constrainDefWithIds, constrainRecursiveDefsWithIds)

{-| Type constraint generation for expressions (Typed pathway).

This module walks canonical expression AST nodes and generates type
constraints while tracking expression IDs to solver variables (via `NodeIds`,
whose state lives in `IO.State`), enabling later retrieval of expression
types from the solver.

The generator is written as ordinary recursive `IO` functions (Design B).
Stack safety relies on the axis classification below: every axis along which
`Can.Expr_` nesting depth is unbounded in practice is walked with an explicit
`IO.loop` spine; everything else recurses directly on the JS stack.


## Expression axis classification (the stack-safety argument)

Linear-unbounded (spine loop required — one `IO.loop` per axis):

  - `Let` / `LetRec` / `LetDestruct` — `let`-chains nest down the BODY one
    level per `let`; the def RHS is a separate (bounded) expression.
    Walked by `constrainLetSpine`.
  - `Binop` — left-associative chains (`1 + 2 + 3`, `a |> f |> g`) nest down
    the LEFT operand; right-associative chains (`a ++ b ++ c`, `f <| g <| x`)
    nest down the RIGHT operand. `constrainBinopSpine` handles both: it
    descends into whichever single operand is itself a `Binop` (left takes
    priority to preserve walk order), deferring the other side. Only a node
    whose operands are BOTH binops costs a JS frame — that is genuine tree
    branching, bounded by the balanced-tree argument below.
  - `Call` — curried application (`((f x) y) z`) nests down the FUNC;
    nested application (`f (g (h x))`) nests down the LAST argument.
    `constrainCallSpine` handles both, preferring the func axis.
  - `If` — `else if` ladders and machine-generated conditionals nest down
    the FINAL (else) branch. Walked by `constrainIfSpine`.
  - `Access` — field chains (`r.a.b.c...`) nest down the record expression.
    Walked by `constrainAccessSpine`.

Bounded (direct recursion OK):

  - `Case` — the scrutinee and each branch body are separate subtrees; a
    `case` nested in a branch costs one JS frame per level, but case-ladders
    are written source (an N-deep ladder needs N written `case`s with their
    own patterns), not data-scaled.
  - `List` / `Tuple` / `Record` / `Update` / `Call` args — children are
    width-bounded element/field/argument lists.
  - `Lambda` — argument patterns are width-bounded; a `\x -> \y -> ...`
    chain requires a written lambda per level (idiomatic Elm uses one
    multi-arg lambda), so depth is written-source-bounded.
  - `Negate` — `-(-(-x))` requires explicit parentheses per level.
  - `Accessor`, `Shader`, literals, and the `Var*` leaf forms — leaves.

A balanced expression tree of depth d holds ~2^d nodes, so genuine branching
depth stays in the low tens even for enormous programs; only the linear axes
above can grow with data size, and each has a spine loop plus a deep-nesting
regression test (see `DeepSpineStackSafetyTest`).


## Spine loop shape

Each spine is a two-phase `IO.loop`:

1.  DESCEND the chain iteratively, at each level allocating and recording
    that node's variable(s) and pushing the level's residual work onto a
    frame list, then advancing to the deep child. The IO operation order is
    identical to the recursive formulation's (allocations happen parent
    first, in source order).
2.  Constrain the first non-matching node (the leaf) via the ordinary
    re-entrant `constrainWithIds`, then FOLD BACK UP the frames (innermost
    first, via `IO.foldM`), combining each frame with the running child
    constraint exactly as the recursive arm would have.


# Constraint Generation with ID Tracking

@docs constrainDefWithIds, constrainRecursiveDefsWithIds

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E exposing (Category(..), Context(..), Expected(..), MaybeName(..), PContext(..), PExpected(..), SubContext(..))
import Compiler.Type.Constrain.Common as Common exposing (Args, Info(..), RigidTypeVar, State(..), TypedArgs(..), getAccessName, getName, makeArgs, toShaderRecord)
import Compiler.Type.Constrain.Typed.NodeIds as NodeIds
import Compiler.Type.Constrain.Typed.Pattern as Pattern
import Compiler.Type.Instantiate as Instantiate
import Compiler.Type.Type as Type exposing (Constraint(..), Type(..))
import Data.Map as DMap
import Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Main as Utils



-- ====== DEFINITIONS ======


{-| Generate constraints for a definition, also tracking node IDs
(expressions and patterns).
-}
constrainDefWithIds : RigidTypeVar -> Can.Def -> Constraint -> IO Constraint
constrainDefWithIds rtv def bodyCon =
    case def of
        Can.Def (A.At region name) args expr ->
            constrainArgsWithIds args
                |> IO.andThen
                    (\props ->
                        let
                            (State headers pvars revCons) =
                                props.state
                        in
                        constrainWithIds rtv expr (NoExpectation props.result)
                            |> IO.map
                                (\exprCon ->
                                    CLet []
                                        props.vars
                                        (Dict.singleton name (A.At region props.tipe))
                                        (CLet []
                                            pvars
                                            headers
                                            (CAnd (List.reverse revCons))
                                            exprCon
                                        )
                                        bodyCon
                                )
                    )

        Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
            let
                newNames : Dict Name ()
                newNames =
                    Dict.diff freeVars rtv
            in
            IO.traverseMapWithKey identity compare (\k _ -> Type.nameToRigid k) (DMap.fromList identity (Dict.toList newNames))
                |> IO.andThen
                    (\newRigidsDMap ->
                        let
                            newRigids : Dict Name IO.Variable
                            newRigids =
                                Dict.fromList (DMap.toList compare newRigidsDMap)

                            newRtv : RigidTypeVar
                            newRtv =
                                Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                        in
                        NodeIds.recordSchemeBinders name newRigids
                            |> IO.andThen
                                (\() ->
                                    constrainTypedArgsWithIds newRtv name typedArgs srcResultType
                                        |> IO.andThen
                                            (\(TypedArgs tipe resultType (State headers pvars revCons)) ->
                                                constrainWithIds newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType)
                                                    |> IO.map
                                                        (\exprCon ->
                                                            CLet (Dict.values newRigids)
                                                                []
                                                                (Dict.singleton name (A.At region tipe))
                                                                (CLet []
                                                                    pvars
                                                                    headers
                                                                    (CAnd (List.reverse revCons))
                                                                    exprCon
                                                                )
                                                                bodyCon
                                                        )
                                            )
                                )
                    )


{-| Generate constraints for recursive definitions, also tracking node IDs
(expressions and patterns).
-}
constrainRecursiveDefsWithIds : RigidTypeVar -> List Can.Def -> Constraint -> IO Constraint
constrainRecursiveDefsWithIds rtv defs bodyCon =
    recDefsHelpWithIds rtv defs bodyCon (Info [] [] Dict.empty) (Info [] [] Dict.empty)


recDefsHelpWithIds : RigidTypeVar -> List Can.Def -> Constraint -> Info -> Info -> IO Constraint
recDefsHelpWithIds rtv defs bodyCon rigidInfo flexInfo =
    case defs of
        [] ->
            let
                (Info rigidVars rigidCons rigidHeaders) =
                    rigidInfo

                (Info flexVars flexCons flexHeaders) =
                    flexInfo
            in
            IO.pure
                (CAnd [ CAnd rigidCons, bodyCon ]
                    |> CLet [] flexVars flexHeaders (CLet [] [] flexHeaders CTrue (CAnd flexCons))
                    |> CLet rigidVars [] rigidHeaders CTrue
                )

        def :: otherDefs ->
            case def of
                Can.Def (A.At region name) args expr ->
                    let
                        (Info flexVars flexCons flexHeaders) =
                            flexInfo
                    in
                    -- Match original: thread accumulated flexVars through pattern state
                    argsHelpWithIds args (State Dict.empty flexVars [])
                        |> IO.andThen
                            (\props ->
                                let
                                    (State headers pvars revCons) =
                                        props.state
                                in
                                constrainWithIds rtv expr (NoExpectation props.result)
                                    |> IO.andThen
                                        (\exprCon ->
                                            let
                                                defCon : Constraint
                                                defCon =
                                                    CLet [] pvars headers (CAnd (List.reverse revCons)) exprCon

                                                -- Match original: just props.vars (flexVars already in pvars)
                                                newFlexInfo : Info
                                                newFlexInfo =
                                                    Info props.vars
                                                        (defCon :: flexCons)
                                                        (Dict.insert name (A.At region props.tipe) flexHeaders)
                                            in
                                            recDefsHelpWithIds rtv otherDefs bodyCon rigidInfo newFlexInfo
                                        )
                            )

                Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
                    let
                        (Info rigidVars rigidCons rigidHeaders) =
                            rigidInfo

                        newNames : Dict Name ()
                        newNames =
                            Dict.diff freeVars rtv
                    in
                    IO.traverseMapWithKey identity compare (\k _ -> Type.nameToRigid k) (DMap.fromList identity (Dict.toList newNames))
                        |> IO.andThen
                            (\newRigidsDMap ->
                                let
                                    newRigids : Dict Name IO.Variable
                                    newRigids =
                                        Dict.fromList (DMap.toList compare newRigidsDMap)

                                    newRtv : RigidTypeVar
                                    newRtv =
                                        Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                                in
                                NodeIds.recordSchemeBinders name newRigids
                                    |> IO.andThen
                                        (\() ->
                                            constrainTypedArgsWithIds newRtv name typedArgs srcResultType
                                                |> IO.andThen
                                                    (\(TypedArgs tipe resultType (State headers pvars revCons)) ->
                                                        constrainWithIds newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType)
                                                            |> IO.andThen
                                                                (\exprCon ->
                                                                    let
                                                                        -- Match original: defCon has empty rigid vars
                                                                        defCon : Constraint
                                                                        defCon =
                                                                            CLet []
                                                                                pvars
                                                                                headers
                                                                                (CAnd (List.reverse revCons))
                                                                                exprCon

                                                                        -- Match original: wrap defCon in CLet that introduces rigids
                                                                        wrappedDefCon : Constraint
                                                                        wrappedDefCon =
                                                                            CLet (Dict.values newRigids) [] Dict.empty defCon CTrue

                                                                        newRigidInfo : Info
                                                                        newRigidInfo =
                                                                            Info (Dict.foldr (\_ -> (::)) rigidVars newRigids) (wrappedDefCon :: rigidCons) (Dict.insert name (A.At region tipe) rigidHeaders)
                                                                    in
                                                                    recDefsHelpWithIds rtv otherDefs bodyCon newRigidInfo flexInfo
                                                                )
                                                    )
                                        )
                            )


{-| Generate constraints for a list of function argument patterns,
also tracking pattern IDs.
-}
constrainArgsWithIds : List Can.Pattern -> IO Args
constrainArgsWithIds args =
    argsHelpWithIds args Common.emptyState


{-| Helper for constraining function arguments with ID tracking.
Recursively processes patterns (width-bounded), building up the function type.
-}
argsHelpWithIds : List Can.Pattern -> State -> IO Args
argsHelpWithIds args state =
    case args of
        [] ->
            Type.mkFlexVar
                |> IO.map
                    (\resultVar ->
                        let
                            resultType : Type
                            resultType =
                                VarN resultVar
                        in
                        makeArgs [ resultVar ] resultType resultType state
                    )

        pattern :: otherArgs ->
            Type.mkFlexVar
                |> IO.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        Pattern.addWithIds pattern (PNoExpectation argType) state
                            |> IO.andThen (\newState -> argsHelpWithIds otherArgs newState)
                            |> IO.map
                                (\props ->
                                    makeArgs (argVar :: props.vars) (FunN argType props.tipe) props.result props.state
                                )
                    )


{-| Generate constraints for explicitly typed function arguments,
also tracking pattern IDs.
-}
constrainTypedArgsWithIds :
    Dict Name Type
    -> Name
    -> List ( Can.Pattern, Can.Type Name )
    -> Can.Type Name
    -> IO TypedArgs
constrainTypedArgsWithIds rtv name args srcResultType =
    typedArgsHelpWithIds rtv name Index.first args srcResultType Common.emptyState


{-| Helper for constraining typed arguments with ID tracking.
Recursively processes pattern-type pairs (width-bounded).
-}
typedArgsHelpWithIds :
    Dict Name Type
    -> Name
    -> Index.ZeroBased
    -> List ( Can.Pattern, Can.Type Name )
    -> Can.Type Name
    -> State
    -> IO TypedArgs
typedArgsHelpWithIds rtv name index args srcResultType state =
    case args of
        [] ->
            Instantiate.fromSrcType rtv srcResultType
                |> IO.map
                    (\resultType ->
                        TypedArgs resultType resultType state
                    )

        ( (A.At region _) as pattern, srcType ) :: otherArgs ->
            Instantiate.fromSrcType rtv srcType
                |> IO.andThen
                    (\argType ->
                        let
                            expected : PExpected Type
                            expected =
                                PFromContext region (PTypedArg name index) argType
                        in
                        Pattern.addWithIds pattern expected state
                            |> IO.andThen
                                (\newState ->
                                    typedArgsHelpWithIds rtv name (Index.next index) otherArgs srcResultType newState
                                )
                            |> IO.map
                                (\(TypedArgs tipe resultType finalState) ->
                                    TypedArgs (FunN argType tipe) resultType finalState
                                )
                    )



-- ====== EXPRESSION DISPATCH ======


{-| Generate constraints for an expression, tracking expression ID → Variable
mappings.

This function dispatches to specialized helpers based on expression type:

  - Group A expressions record a node var via NodeIds.recordNodeVar.
    This includes: Int, Negate, Binop, Call, If, Case, Access, Update,
    Accessor, List, Tuple, Record, Lambda, Let, LetRec, LetDestruct.
  - Group B expressions (Str, Chr, Float, Unit, Shader, and leaf Var\* forms)
    use the generic path that allocates a synthetic exprVar via
    recordSyntheticExprVar, later fixed by PostSolve.

The linear-unbounded axes (see the module docs) route to their spine loops;
everything else recurses directly.

-}
constrainWithIds : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainWithIds rtv ((A.At region exprInfo) as expr) expected =
    case exprInfo.node of
        -- Group A: specialized helpers that record the natural result var
        Can.Int _ ->
            constrainIntWithIds region exprInfo.id expected

        Can.Negate subExpr ->
            constrainNegateWithIds rtv region exprInfo.id subExpr expected

        Can.Binop _ _ _ _ _ _ ->
            constrainBinopSpine rtv expr expected

        Can.Call _ _ ->
            constrainCallSpine rtv expr expected

        Can.If _ _ ->
            constrainIfSpine rtv expr expected

        Can.Case caseExpr branches ->
            constrainCaseWithIds rtv region exprInfo.id caseExpr branches expected

        Can.Access _ _ ->
            constrainAccessSpine rtv expr expected

        Can.Update updateExpr fields ->
            constrainUpdateWithIds rtv region exprInfo.id updateExpr fields expected

        -- Group A: accessor, containers, lambdas, and let expressions
        Can.Accessor field ->
            constrainAccessorGroupAWithIds region exprInfo.id field expected

        Can.List elements ->
            constrainListGroupAWithIds rtv region exprInfo.id elements expected

        Can.Tuple a b cs ->
            constrainTupleGroupAWithIds rtv region exprInfo.id a b cs expected

        Can.Record fields ->
            constrainRecordGroupAWithIds rtv region exprInfo.id fields expected

        Can.Lambda args body ->
            constrainLambdaGroupAWithIds rtv region exprInfo.id args body expected

        Can.Let _ _ ->
            constrainLetSpine rtv expr expected

        Can.LetRec _ _ ->
            constrainLetSpine rtv expr expected

        Can.LetDestruct _ _ _ ->
            constrainLetSpine rtv expr expected

        -- Group B: Str, Chr, Float, Unit, Shader, Var* leaf forms
        _ ->
            constrainGenericWithIds rtv region exprInfo expected


{-| Generic implementation for expressions without natural result variables.

Allocates a synthetic exprVar for ID tracking, then generates constraints
matching the erased path, adding a CEqual to connect exprVar to the expected
type. On the erased pathway (recording off) the wrapper is skipped entirely.

-}
constrainGenericWithIds : RigidTypeVar -> A.Region -> Can.ExprInfo -> E.Expected Type -> IO Constraint
constrainGenericWithIds rtv region info expected =
    IO.getNodeIds
        |> IO.andThen
            (\state ->
                if state.recording then
                    -- Typed pathway: allocate a synthetic placeholder var for this
                    -- Group B node (Str, Chr, Float, Unit, Shader, Var*), record it,
                    -- and tie it to the expected type so nodeTypes gets the resolved type.
                    Type.mkFlexVar
                        |> IO.andThen
                            (\exprVar ->
                                NodeIds.recordSyntheticExprVar info.id exprVar
                                    |> IO.andThen
                                        (\() ->
                                            let
                                                exprType : Type
                                                exprType =
                                                    VarN exprVar
                                            in
                                            constrainNodeWithIds rtv region info.node expected
                                                |> IO.map
                                                    (\con ->
                                                        Type.exists [ exprVar ]
                                                            (CAnd
                                                                [ con
                                                                , CEqual region E.List exprType expected
                                                                ]
                                                            )
                                                    )
                                        )
                            )

                else
                    -- Erased pathway: no synthetic placeholder var; emit the node's
                    -- constraint directly against the expected type.
                    constrainNodeWithIds rtv region info.node expected
            )


{-| Specialized Int handling - record the number variable directly.
-}
constrainIntWithIds : A.Region -> Int -> E.Expected Type -> IO Constraint
constrainIntWithIds region exprId expected =
    Type.mkFlexNumber
        |> IO.andThen
            (\var ->
                NodeIds.recordNodeVar exprId var
                    |> IO.map
                        (\() ->
                            Type.exists [ var ] (CEqual region E.Number (VarN var) expected)
                        )
            )


{-| Specialized Negate handling - record the number variable directly.
-}
constrainNegateWithIds : RigidTypeVar -> A.Region -> Int -> Can.Expr -> E.Expected Type -> IO Constraint
constrainNegateWithIds rtv region exprId expr expected =
    Type.mkFlexNumber
        |> IO.andThen
            (\numberVar ->
                NodeIds.recordNodeVar exprId numberVar
                    |> IO.andThen
                        (\() ->
                            let
                                numberType : Type
                                numberType =
                                    VarN numberVar
                            in
                            constrainWithIds rtv expr (FromContext region Negate numberType)
                                |> IO.map
                                    (\numberCon ->
                                        Type.exists [ numberVar ]
                                            (CAnd [ numberCon, CEqual region E.Number numberType expected ])
                                    )
                        )
            )



-- ====== LET SPINE ======


{-| The residual work of one `let` level: the def(s) to constrain and the
Group A wrapping, applied once the deeper body is done.
-}
type LetPayload
    = LetDef Can.Def
    | LetRecDefs (List Can.Def)
    | LetDestructPat Can.Pattern Can.Expr


type alias LetFrame =
    { region : A.Region
    , exprVar : IO.Variable
    , payload : LetPayload
    , expected : E.Expected Type
    }


{-| Walk a `let`-chain iteratively (constant JS stack).

Descend: at each `Let`/`LetRec`/`LetDestruct` allocate + record the node's
exprVar and push the defs as a frame; advance into the body. Constrain the
first non-let body via the ordinary dispatcher. Fold up: constrain each
level's defs against the running body constraint (innermost first) and apply
the Group A exists/CEqual wrapper — exactly what the recursive arms did.

-}
constrainLetSpine : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainLetSpine rtv expr expected =
    IO.loop (letSpineStep rtv) ( expr, expected, [] )
        |> IO.andThen
            (\( leafCon, frames ) -> IO.foldM (applyLetFrame rtv) leafCon frames)


letSpineStep :
    RigidTypeVar
    -> ( Can.Expr, E.Expected Type, List LetFrame )
    -> IO (IO.Step ( Can.Expr, E.Expected Type, List LetFrame ) ( Constraint, List LetFrame ))
letSpineStep rtv ( (A.At region exprInfo) as current, expected, frames ) =
    let
        descend : LetPayload -> Can.Expr -> IO (IO.Step ( Can.Expr, E.Expected Type, List LetFrame ) ( Constraint, List LetFrame ))
        descend payload body =
            Type.mkFlexVar
                |> IO.andThen
                    (\exprVar ->
                        NodeIds.recordNodeVar exprInfo.id exprVar
                            |> IO.map
                                (\() ->
                                    IO.Loop
                                        ( body
                                        , NoExpectation (VarN exprVar)
                                        , { region = region, exprVar = exprVar, payload = payload, expected = expected } :: frames
                                        )
                                )
                    )
    in
    case exprInfo.node of
        Can.Let def body ->
            descend (LetDef def) body

        Can.LetRec defs body ->
            descend (LetRecDefs defs) body

        Can.LetDestruct pattern defExpr body ->
            descend (LetDestructPat pattern defExpr) body

        _ ->
            constrainWithIds rtv current expected
                |> IO.map (\con -> IO.Done ( con, frames ))


applyLetFrame : RigidTypeVar -> Constraint -> LetFrame -> IO Constraint
applyLetFrame rtv bodyCon frame =
    (case frame.payload of
        LetDef def ->
            constrainDefWithIds rtv def bodyCon

        LetRecDefs defs ->
            constrainRecursiveDefsWithIds rtv defs bodyCon

        LetDestructPat pattern defExpr ->
            constrainDestructWithIds rtv frame.region pattern defExpr bodyCon
    )
        |> IO.map
            (\letCon ->
                Type.exists [ frame.exprVar ]
                    (CAnd
                        [ letCon
                        , CEqual frame.region Lambda (VarN frame.exprVar) frame.expected
                        ]
                    )
            )



-- ====== BINOP SPINE ======


{-| Everything of one binop level that is independent of its operand
constraints.
-}
type alias BinopLevel =
    { region : A.Region
    , op : Name
    , opCon : Constraint
    , leftVar : IO.Variable
    , rightVar : IO.Variable
    , answerVar : IO.Variable
    , answerType : Type
    , expected : E.Expected Type
    }


type BinopFrame
    = BinopDeferRight BinopLevel Can.Expr (E.Expected Type)
    | BinopLeftDone BinopLevel Constraint


isBinopNode : Can.Expr -> Bool
isBinopNode (A.At _ info) =
    case info.node of
        Can.Binop _ _ _ _ _ _ ->
            True

        _ ->
            False


assembleBinop : BinopLevel -> Constraint -> Constraint -> Constraint
assembleBinop level leftCon rightCon =
    Type.exists [ level.leftVar, level.rightVar, level.answerVar ]
        (CAnd
            [ level.opCon
            , leftCon
            , rightCon
            , CEqual level.region (CallResult (OpName level.op)) level.answerType level.expected
            ]
        )


{-| Walk a binop chain iteratively (constant JS stack), whichever operand it
nests down.

At each level: allocate left/right/answer vars and record the answer var
(exactly the recursive order). Then:

  - left operand is a binop → defer the right operand to the fold-up and
    descend left (preserves left-before-right constraining);
  - otherwise constrain the left operand now; if the right operand is a
    binop, descend right; else constrain it and close the level (spine leaf).

Only when BOTH operands are binops does the deferred right side re-enter
`constrainWithIds` (a fresh spine) during fold-up — genuine branching.

-}
constrainBinopSpine : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainBinopSpine rtv expr expected =
    IO.loop (binopSpineStep rtv) ( expr, expected, [] )
        |> IO.andThen
            (\( leafCon, frames ) -> IO.foldM (applyBinopFrame rtv) leafCon frames)


binopSpineStep :
    RigidTypeVar
    -> ( Can.Expr, E.Expected Type, List BinopFrame )
    -> IO (IO.Step ( Can.Expr, E.Expected Type, List BinopFrame ) ( Constraint, List BinopFrame ))
binopSpineStep rtv ( (A.At region exprInfo) as current, expected, frames ) =
    case exprInfo.node of
        Can.Binop op _ _ annotation leftExpr rightExpr ->
            Type.mkFlexVar
                |> IO.andThen
                    (\leftVar ->
                        Type.mkFlexVar
                            |> IO.andThen
                                (\rightVar ->
                                    Type.mkFlexVar
                                        |> IO.andThen
                                            (\answerVar ->
                                                -- Record answerVar as the type for this binop expression
                                                NodeIds.recordNodeVar exprInfo.id answerVar
                                                    |> IO.andThen
                                                        (\() ->
                                                            let
                                                                leftType : Type
                                                                leftType =
                                                                    VarN leftVar

                                                                rightType : Type
                                                                rightType =
                                                                    VarN rightVar

                                                                answerType : Type
                                                                answerType =
                                                                    VarN answerVar

                                                                binopType : Type
                                                                binopType =
                                                                    Type.funType leftType (Type.funType rightType answerType)

                                                                level : BinopLevel
                                                                level =
                                                                    { region = region
                                                                    , op = op
                                                                    , opCon = CForeign region op annotation (NoExpectation binopType)
                                                                    , leftVar = leftVar
                                                                    , rightVar = rightVar
                                                                    , answerVar = answerVar
                                                                    , answerType = answerType
                                                                    , expected = expected
                                                                    }

                                                                leftExpected : E.Expected Type
                                                                leftExpected =
                                                                    FromContext region (OpLeft op) leftType

                                                                rightExpected : E.Expected Type
                                                                rightExpected =
                                                                    FromContext region (OpRight op) rightType
                                                            in
                                                            if isBinopNode leftExpr then
                                                                IO.pure (IO.Loop ( leftExpr, leftExpected, BinopDeferRight level rightExpr rightExpected :: frames ))

                                                            else
                                                                constrainWithIds rtv leftExpr leftExpected
                                                                    |> IO.andThen
                                                                        (\leftCon ->
                                                                            if isBinopNode rightExpr then
                                                                                IO.pure (IO.Loop ( rightExpr, rightExpected, BinopLeftDone level leftCon :: frames ))

                                                                            else
                                                                                constrainWithIds rtv rightExpr rightExpected
                                                                                    |> IO.map
                                                                                        (\rightCon ->
                                                                                            IO.Done ( assembleBinop level leftCon rightCon, frames )
                                                                                        )
                                                                        )
                                                        )
                                            )
                                )
                    )

        _ ->
            -- Unreachable: the spine only enters/loops on Binop nodes.
            constrainWithIds rtv current expected
                |> IO.map (\con -> IO.Done ( con, frames ))


applyBinopFrame : RigidTypeVar -> Constraint -> BinopFrame -> IO Constraint
applyBinopFrame rtv childCon frame =
    case frame of
        BinopDeferRight level rightExpr rightExpected ->
            constrainWithIds rtv rightExpr rightExpected
                |> IO.map (\rightCon -> assembleBinop level childCon rightCon)

        BinopLeftDone level leftCon ->
            IO.pure (assembleBinop level leftCon childCon)



-- ====== CALL SPINE ======


{-| Everything of one call level that is independent of its func/arg
constraints.
-}
type alias CallLevel =
    { region : A.Region
    , funcRegion : A.Region
    , maybeName : MaybeName
    , funcVar : IO.Variable
    , resultVar : IO.Variable
    , funcType : Type
    , resultType : Type
    , numArgs : Int
    , expected : E.Expected Type
    }


type CallFrame
    = CallDeferArgs CallLevel (List Can.Expr)
    | CallLastArg CallLevel Constraint (List IO.Variable) (List Type) (List Constraint) IO.Variable Type


isCallNode : Can.Expr -> Bool
isCallNode (A.At _ info) =
    case info.node of
        Can.Call _ _ ->
            True

        _ ->
            False


assembleCall : CallLevel -> Constraint -> List IO.Variable -> List Type -> List Constraint -> Constraint
assembleCall level funcCon argVars argTypes argCons =
    let
        arityType : Type
        arityType =
            List.foldr FunN level.resultType argTypes

        category : Category
        category =
            CallResult level.maybeName
    in
    Type.exists (level.funcVar :: level.resultVar :: argVars)
        (CAnd
            [ funcCon
            , CEqual level.funcRegion category level.funcType (FromContext level.region (CallArity level.maybeName level.numArgs) arityType)
            , CAnd argCons
            , CEqual level.region category level.resultType level.expected
            ]
        )


{-| Walk a call chain iteratively (constant JS stack), down either the func
axis (curried application) or the last-argument axis (nested application).

At each level: allocate funcVar/resultVar and record the result var (exactly
the recursive order). Then:

  - func is a call → defer all args to the fold-up and descend into func;
  - otherwise constrain func and the args in order; if the LAST arg is a
    call, descend into it; else close the level (spine leaf).

-}
constrainCallSpine : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainCallSpine rtv expr expected =
    IO.loop (callSpineStep rtv) ( expr, expected, [] )
        |> IO.andThen
            (\( leafCon, frames ) -> IO.foldM (applyCallFrame rtv) leafCon frames)


callSpineStep :
    RigidTypeVar
    -> ( Can.Expr, E.Expected Type, List CallFrame )
    -> IO (IO.Step ( Can.Expr, E.Expected Type, List CallFrame ) ( Constraint, List CallFrame ))
callSpineStep rtv ( (A.At region exprInfo) as current, expected, frames ) =
    case exprInfo.node of
        Can.Call ((A.At funcRegion _) as func) args ->
            Type.mkFlexVar
                |> IO.andThen
                    (\funcVar ->
                        Type.mkFlexVar
                            |> IO.andThen
                                (\resultVar ->
                                    -- Record resultVar for this call expression
                                    NodeIds.recordNodeVar exprInfo.id resultVar
                                        |> IO.andThen
                                            (\() ->
                                                let
                                                    level : CallLevel
                                                    level =
                                                        { region = region
                                                        , funcRegion = funcRegion
                                                        , maybeName = getName func
                                                        , funcVar = funcVar
                                                        , resultVar = resultVar
                                                        , funcType = VarN funcVar
                                                        , resultType = VarN resultVar
                                                        , numArgs = List.length args
                                                        , expected = expected
                                                        }
                                                in
                                                if isCallNode func then
                                                    IO.pure (IO.Loop ( func, E.NoExpectation level.funcType, CallDeferArgs level args :: frames ))

                                                else
                                                    constrainWithIds rtv func (E.NoExpectation level.funcType)
                                                        |> IO.andThen
                                                            (\funcCon ->
                                                                callSpineArgs rtv level funcCon Index.first args [] [] [] frames
                                                            )
                                            )
                                )
                    )

        _ ->
            -- Unreachable: the spine only enters/loops on Call nodes.
            constrainWithIds rtv current expected
                |> IO.map (\con -> IO.Done ( con, frames ))


{-| Process a level's arguments in order (width-bounded), descending into the
last argument when it is itself a call.
-}
callSpineArgs :
    RigidTypeVar
    -> CallLevel
    -> Constraint
    -> Index.ZeroBased
    -> List Can.Expr
    -> List IO.Variable
    -> List Type
    -> List Constraint
    -> List CallFrame
    -> IO (IO.Step ( Can.Expr, E.Expected Type, List CallFrame ) ( Constraint, List CallFrame ))
callSpineArgs rtv level funcCon index remaining accVars accTypes accCons frames =
    case remaining of
        [] ->
            IO.pure
                (IO.Done
                    ( assembleCall level funcCon (List.reverse accVars) (List.reverse accTypes) (List.reverse accCons)
                    , frames
                    )
                )

        [ lastArg ] ->
            Type.mkFlexVar
                |> IO.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar

                            argExpected : E.Expected Type
                            argExpected =
                                FromContext level.region (CallArg level.maybeName index) argType
                        in
                        if isCallNode lastArg then
                            IO.pure
                                (IO.Loop
                                    ( lastArg
                                    , argExpected
                                    , CallLastArg level funcCon (List.reverse accVars) (List.reverse accTypes) (List.reverse accCons) argVar argType :: frames
                                    )
                                )

                        else
                            constrainWithIds rtv lastArg argExpected
                                |> IO.map
                                    (\argCon ->
                                        IO.Done
                                            ( assembleCall level
                                                funcCon
                                                (List.reverse (argVar :: accVars))
                                                (List.reverse (argType :: accTypes))
                                                (List.reverse (argCon :: accCons))
                                            , frames
                                            )
                                    )
                    )

        arg :: rest ->
            Type.mkFlexVar
                |> IO.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        constrainWithIds rtv arg (FromContext level.region (CallArg level.maybeName index) argType)
                            |> IO.andThen
                                (\argCon ->
                                    callSpineArgs rtv level funcCon (Index.next index) rest (argVar :: accVars) (argType :: accTypes) (argCon :: accCons) frames
                                )
                    )


applyCallFrame : RigidTypeVar -> Constraint -> CallFrame -> IO Constraint
applyCallFrame rtv childCon frame =
    case frame of
        CallDeferArgs level args ->
            -- childCon is the funcCon of the descended func; args were deferred.
            constrainCallArgsWithIds rtv level Index.first args [] [] []
                |> IO.map
                    (\( argVars, argTypes, argCons ) ->
                        assembleCall level childCon argVars argTypes argCons
                    )

        CallLastArg level funcCon argVars argTypes argCons lastVar lastType ->
            IO.pure
                (assembleCall level
                    funcCon
                    (argVars ++ [ lastVar ])
                    (argTypes ++ [ lastType ])
                    (argCons ++ [ childCon ])
                )


{-| Constrain a call's arguments by direct recursion (width-bounded); used on
the fold-up path where the loop is no longer available.
-}
constrainCallArgsWithIds :
    RigidTypeVar
    -> CallLevel
    -> Index.ZeroBased
    -> List Can.Expr
    -> List IO.Variable
    -> List Type
    -> List Constraint
    -> IO ( List IO.Variable, List Type, List Constraint )
constrainCallArgsWithIds rtv level index args accVars accTypes accCons =
    case args of
        [] ->
            IO.pure ( List.reverse accVars, List.reverse accTypes, List.reverse accCons )

        arg :: rest ->
            Type.mkFlexVar
                |> IO.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        constrainWithIds rtv arg (FromContext level.region (CallArg level.maybeName index) argType)
                            |> IO.andThen
                                (\argCon ->
                                    constrainCallArgsWithIds rtv level (Index.next index) rest (argVar :: accVars) (argType :: accTypes) (argCon :: accCons)
                                )
                    )



-- ====== IF SPINE ======


{-| One deferred `if` level: the constraints of everything except the final
(else) branch, plus the assembly closure that finishes the level once the
final branch constraint arrives.
-}
type alias IfFrame =
    { assemble : List Constraint -> Constraint
    , earlierBranchCons : List Constraint
    }


isIfNode : Can.Expr -> Bool
isIfNode (A.At _ info) =
    case info.node of
        Can.If _ _ ->
            True

        _ ->
            False


{-| Walk an `if`/`else if` ladder iteratively (constant JS stack) down the
final (else) branch.

At each level, in exactly the recursive order: constrain all conditions,
allocate/record the branch var per the expected shape, constrain the `then`
branches in index order, and descend into the final branch when it is itself
an `if` (else constrain it and close the level).

-}
constrainIfSpine : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainIfSpine rtv expr expected =
    IO.loop (ifSpineStep rtv) ( expr, expected, [] )
        |> IO.andThen
            (\( leafCon, frames ) -> IO.foldM applyIfFrame leafCon frames)


ifSpineStep :
    RigidTypeVar
    -> ( Can.Expr, E.Expected Type, List IfFrame )
    -> IO (IO.Step ( Can.Expr, E.Expected Type, List IfFrame ) ( Constraint, List IfFrame ))
ifSpineStep rtv ( (A.At region exprInfo) as current, expected, frames ) =
    case exprInfo.node of
        Can.If branches finally ->
            let
                boolExpect : Expected Type
                boolExpect =
                    FromContext region IfCondition Type.bool

                ( conditions, exprs ) =
                    List.foldr (\( c, e ) ( cs, es ) -> ( c :: cs, e :: es )) ( [], [ finally ] ) branches
            in
            constrainExprsWithIds rtv conditions boolExpect []
                |> IO.andThen
                    (\condCons ->
                        (case expected of
                            FromAnnotation name arity _ tipe ->
                                -- Record ID with the expected type (tipe is the type var)
                                (case tipe of
                                    VarN v ->
                                        NodeIds.recordNodeVar exprInfo.id v
                                            |> IO.map (\() -> Nothing)

                                    _ ->
                                        -- Need to create a var for tracking, and constrain it to equal the annotation type
                                        Type.mkFlexVar
                                            |> IO.andThen
                                                (\v ->
                                                    NodeIds.recordNodeVar exprInfo.id v
                                                        |> IO.map (\() -> Just v)
                                                )
                                )
                                    |> IO.map
                                        (\maybeFlexVar ->
                                            ( \index -> FromAnnotation name arity (TypedIfBranch index) tipe
                                            , \branchCons ->
                                                case maybeFlexVar of
                                                    Just flexVar ->
                                                        Type.exists [ flexVar ]
                                                            (CAnd
                                                                [ CAnd condCons
                                                                , CAnd branchCons
                                                                , CEqual region If (VarN flexVar) (NoExpectation tipe)
                                                                ]
                                                            )

                                                    Nothing ->
                                                        CAnd (CAnd condCons :: branchCons)
                                            )
                                        )

                            _ ->
                                Type.mkFlexVar
                                    |> IO.andThen
                                        (\branchVar ->
                                            -- Record branchVar for this if expression
                                            NodeIds.recordNodeVar exprInfo.id branchVar
                                                |> IO.map
                                                    (\() ->
                                                        let
                                                            branchType : Type
                                                            branchType =
                                                                VarN branchVar
                                                        in
                                                        ( \index -> FromContext region (IfBranch index) branchType
                                                        , \branchCons ->
                                                            Type.exists [ branchVar ]
                                                                (CAnd
                                                                    [ CAnd condCons
                                                                    , CAnd branchCons
                                                                    , CEqual region If branchType expected
                                                                    ]
                                                                )
                                                        )
                                                    )
                                        )
                        )
                            |> IO.andThen
                                (\( mkExpected, assemble ) ->
                                    ifSpineBranches rtv mkExpected assemble Index.first exprs [] frames
                                )
                    )

        _ ->
            -- Unreachable: the spine only enters/loops on If nodes.
            constrainWithIds rtv current expected
                |> IO.map (\con -> IO.Done ( con, frames ))


{-| Constrain a level's branch expressions in index order (width-bounded),
descending into the final one when it is itself an `if`.
-}
ifSpineBranches :
    RigidTypeVar
    -> (Index.ZeroBased -> E.Expected Type)
    -> (List Constraint -> Constraint)
    -> Index.ZeroBased
    -> List Can.Expr
    -> List Constraint
    -> List IfFrame
    -> IO (IO.Step ( Can.Expr, E.Expected Type, List IfFrame ) ( Constraint, List IfFrame ))
ifSpineBranches rtv mkExpected assemble index remaining accCons frames =
    case remaining of
        [] ->
            -- Unreachable: exprs always ends with the final branch.
            IO.pure (IO.Done ( assemble (List.reverse accCons), frames ))

        [ finalExpr ] ->
            if isIfNode finalExpr then
                IO.pure
                    (IO.Loop
                        ( finalExpr
                        , mkExpected index
                        , { assemble = assemble, earlierBranchCons = List.reverse accCons } :: frames
                        )
                    )

            else
                constrainWithIds rtv finalExpr (mkExpected index)
                    |> IO.map
                        (\con -> IO.Done ( assemble (List.reverse (con :: accCons)), frames ))

        branchExpr :: rest ->
            constrainWithIds rtv branchExpr (mkExpected index)
                |> IO.andThen
                    (\con ->
                        ifSpineBranches rtv mkExpected assemble (Index.next index) rest (con :: accCons) frames
                    )


applyIfFrame : Constraint -> IfFrame -> IO Constraint
applyIfFrame childCon frame =
    IO.pure (frame.assemble (frame.earlierBranchCons ++ [ childCon ]))



-- ====== ACCESS SPINE ======


type alias AccessFrame =
    { region : A.Region
    , field : Name
    , fieldType : Type
    , fieldVar : IO.Variable
    , extVar : IO.Variable
    , expected : E.Expected Type
    }


{-| Walk a field-access chain (`r.a.b.c...`) iteratively (constant JS stack)
down the record expression.

At each level allocate ext/field vars and record the field var (exactly the
recursive order); constrain the first non-access record expression via the
ordinary dispatcher; fold up applying each level's exists/CEqual wrapper.

-}
constrainAccessSpine : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainAccessSpine rtv expr expected =
    IO.loop (accessSpineStep rtv) ( expr, expected, [] )
        |> IO.andThen
            (\( leafCon, frames ) -> IO.foldM applyAccessFrame leafCon frames)


accessSpineStep :
    RigidTypeVar
    -> ( Can.Expr, E.Expected Type, List AccessFrame )
    -> IO (IO.Step ( Can.Expr, E.Expected Type, List AccessFrame ) ( Constraint, List AccessFrame ))
accessSpineStep rtv ( (A.At region exprInfo) as current, expected, frames ) =
    case exprInfo.node of
        Can.Access childExpr (A.At accessRegion field) ->
            Type.mkFlexVar
                |> IO.andThen
                    (\extVar ->
                        Type.mkFlexVar
                            |> IO.andThen
                                (\fieldVar ->
                                    -- Record fieldVar as the type for this access expression
                                    NodeIds.recordNodeVar exprInfo.id fieldVar
                                        |> IO.map
                                            (\() ->
                                                let
                                                    extType : Type
                                                    extType =
                                                        VarN extVar

                                                    fieldType : Type
                                                    fieldType =
                                                        VarN fieldVar

                                                    recordType : Type
                                                    recordType =
                                                        RecordN (Dict.singleton field fieldType) extType

                                                    context : Context
                                                    context =
                                                        RecordAccess (A.toRegion childExpr) (getAccessName childExpr) accessRegion field
                                                in
                                                IO.Loop
                                                    ( childExpr
                                                    , FromContext region context recordType
                                                    , { region = region
                                                      , field = field
                                                      , fieldType = fieldType
                                                      , fieldVar = fieldVar
                                                      , extVar = extVar
                                                      , expected = expected
                                                      }
                                                        :: frames
                                                    )
                                            )
                                )
                    )

        _ ->
            constrainWithIds rtv current expected
                |> IO.map (\con -> IO.Done ( con, frames ))


applyAccessFrame : Constraint -> AccessFrame -> IO Constraint
applyAccessFrame recordCon frame =
    IO.pure
        (Type.exists [ frame.fieldVar, frame.extVar ]
            (CAnd
                [ recordCon
                , CEqual frame.region (Access frame.field) frame.fieldType frame.expected
                ]
            )
        )



-- ====== GROUP A WRAPPERS (bounded nodes) ======


{-| Specialized Accessor handling - treat `.field` as Group A and
record a node variable for the accessor expression's type.
-}
constrainAccessorGroupAWithIds : A.Region -> Int -> Name -> E.Expected Type -> IO Constraint
constrainAccessorGroupAWithIds region exprId field expected =
    Type.mkFlexVar
        |> IO.andThen
            (\exprVar ->
                -- Record exprVar as the type variable for this accessor expression
                NodeIds.recordNodeVar exprId exprVar
                    |> IO.andThen
                        (\() ->
                            let
                                exprType : Type
                                exprType =
                                    VarN exprVar
                            in
                            -- Reuse existing accessor constraints, then tie exprVar to `expected`
                            constrainAccessorWithIds region field expected
                                |> IO.map
                                    (\accessorCon ->
                                        Type.exists [ exprVar ]
                                            (CAnd
                                                [ accessorCon
                                                , CEqual region E.List exprType expected
                                                ]
                                            )
                                    )
                        )
            )


{-| Group A wrapper for List expressions.
-}
constrainListGroupAWithIds : RigidTypeVar -> A.Region -> Int -> List Can.Expr -> E.Expected Type -> IO Constraint
constrainListGroupAWithIds rtv region exprId elements expected =
    Type.mkFlexVar
        |> IO.andThen
            (\exprVar ->
                NodeIds.recordNodeVar exprId exprVar
                    |> IO.andThen
                        (\() ->
                            let
                                exprType : Type
                                exprType =
                                    VarN exprVar
                            in
                            constrainListWithIds rtv region elements expected
                                |> IO.map
                                    (\listCon ->
                                        Type.exists [ exprVar ]
                                            (CAnd
                                                [ listCon
                                                , CEqual region E.List exprType expected
                                                ]
                                            )
                                    )
                        )
            )


{-| Group A wrapper for Tuple expressions.
-}
constrainTupleGroupAWithIds : RigidTypeVar -> A.Region -> Int -> Can.Expr -> Can.Expr -> List Can.Expr -> E.Expected Type -> IO Constraint
constrainTupleGroupAWithIds rtv region exprId a b cs expected =
    Type.mkFlexVar
        |> IO.andThen
            (\exprVar ->
                NodeIds.recordNodeVar exprId exprVar
                    |> IO.andThen
                        (\() ->
                            let
                                exprType : Type
                                exprType =
                                    VarN exprVar
                            in
                            constrainTupleWithIds rtv region a b cs expected
                                |> IO.map
                                    (\tupleCon ->
                                        Type.exists [ exprVar ]
                                            (CAnd
                                                [ tupleCon
                                                , CEqual region Tuple exprType expected
                                                ]
                                            )
                                    )
                        )
            )


{-| Group A wrapper for Record literal expressions.
-}
constrainRecordGroupAWithIds : RigidTypeVar -> A.Region -> Int -> DMap.Dict String (A.Located Name) Can.Expr -> E.Expected Type -> IO Constraint
constrainRecordGroupAWithIds rtv region exprId fields expected =
    Type.mkFlexVar
        |> IO.andThen
            (\exprVar ->
                NodeIds.recordNodeVar exprId exprVar
                    |> IO.andThen
                        (\() ->
                            let
                                exprType : Type
                                exprType =
                                    VarN exprVar
                            in
                            constrainRecordWithIds rtv region fields expected
                                |> IO.map
                                    (\recordCon ->
                                        Type.exists [ exprVar ]
                                            (CAnd
                                                [ recordCon
                                                , CEqual region Record exprType expected
                                                ]
                                            )
                                    )
                        )
            )


{-| Group A wrapper for Lambda expressions.
-}
constrainLambdaGroupAWithIds : RigidTypeVar -> A.Region -> Int -> List Can.Pattern -> Can.Expr -> E.Expected Type -> IO Constraint
constrainLambdaGroupAWithIds rtv region exprId args body expected =
    Type.mkFlexVar
        |> IO.andThen
            (\exprVar ->
                NodeIds.recordNodeVar exprId exprVar
                    |> IO.andThen
                        (\() ->
                            let
                                exprType : Type
                                exprType =
                                    VarN exprVar
                            in
                            constrainLambdaWithIds rtv region args body expected
                                |> IO.map
                                    (\lambdaCon ->
                                        Type.exists [ exprVar ]
                                            (CAnd
                                                [ lambdaCon
                                                , CEqual region Lambda exprType expected
                                                ]
                                            )
                                    )
                        )
            )



-- ====== GROUP B NODE DISPATCH ======


{-| Constrain a node's structure without the Group A recording wrapper.

Reachable only for the Group B leaf forms (Str, Chr, Float, Unit, Shader,
Var\*) via `constrainGenericWithIds`; the composite arms are defensive
(their nodes are dispatched to Group A helpers by `constrainWithIds`).

-}
constrainNodeWithIds : RigidTypeVar -> A.Region -> Can.Expr_ -> E.Expected Type -> IO Constraint
constrainNodeWithIds rtv region node expected =
    case node of
        Can.VarLocal name ->
            IO.pure (CLocal region name expected)

        Can.VarTopLevel _ name ->
            IO.pure (CLocal region name expected)

        Can.VarKernel _ _ _ ->
            IO.pure CTrue

        Can.VarForeign _ name annotation ->
            IO.pure (CForeign region name annotation expected)

        Can.VarCtor _ _ name _ annotation ->
            IO.pure (CForeign region name annotation expected)

        Can.VarDebug _ name annotation ->
            IO.pure (CForeign region name annotation expected)

        Can.VarOperator op _ _ annotation ->
            IO.pure (CForeign region op annotation expected)

        Can.Str _ ->
            IO.pure (CEqual region String Type.string expected)

        Can.Chr _ ->
            IO.pure (CEqual region Char Type.char expected)

        -- Group A: handled by constrainIntWithIds
        Can.Int _ ->
            Type.mkFlexNumber
                |> IO.map (\var -> Type.exists [ var ] (CEqual region E.Number (VarN var) expected))

        Can.Float _ ->
            IO.pure (CEqual region Float Type.float expected)

        Can.Unit ->
            IO.pure (CEqual region Unit UnitN expected)

        Can.List elements ->
            constrainListWithIds rtv region elements expected

        Can.Negate expr ->
            -- In generic path, create fresh var
            Type.mkFlexNumber
                |> IO.andThen
                    (\numberVar ->
                        let
                            numberType : Type
                            numberType =
                                VarN numberVar
                        in
                        constrainWithIds rtv expr (FromContext region Negate numberType)
                            |> IO.map
                                (\numberCon ->
                                    Type.exists [ numberVar ]
                                        (CAnd [ numberCon, CEqual region E.Number numberType expected ])
                                )
                    )

        Can.Lambda args body ->
            constrainLambdaWithIds rtv region args body expected

        Can.Binop op _ _ annotation leftExpr rightExpr ->
            constrainBinopNodeWithIds rtv region op annotation leftExpr rightExpr expected

        Can.Call func argsList ->
            constrainCallNodeWithIds rtv region func argsList expected

        Can.If branches finally ->
            constrainIfNodeWithIds rtv region branches finally expected

        Can.Case expr branches ->
            constrainCaseNodeWithIds rtv region expr branches expected

        Can.Let def body ->
            constrainWithIds rtv body expected
                |> IO.andThen (constrainDefWithIds rtv def)

        Can.LetRec defs body ->
            constrainWithIds rtv body expected
                |> IO.andThen (constrainRecursiveDefsWithIds rtv defs)

        Can.LetDestruct pattern expr body ->
            constrainWithIds rtv body expected
                |> IO.andThen (constrainDestructWithIds rtv region pattern expr)

        Can.Accessor field ->
            constrainAccessorWithIds region field expected

        -- Group A: handled by constrainAccessSpine
        Can.Access _ _ ->
            -- Should not reach here since Access is handled by Group A dispatch
            IO.pure CTrue

        -- Group A: handled by constrainUpdateWithIds
        Can.Update _ _ ->
            -- Should not reach here since Update is handled by Group A dispatch
            IO.pure CTrue

        Can.Record fields ->
            constrainRecordWithIds rtv region fields expected

        Can.Tuple a b cs ->
            constrainTupleWithIds rtv region a b cs expected

        Can.Shader _ types ->
            constrainShaderWithIds region types expected



-- ====== NODE HELPERS ======


constrainShaderWithIds : A.Region -> Shader.Types -> Expected Type -> IO Constraint
constrainShaderWithIds region (Shader.Types attributes uniforms varyings) expected =
    Type.mkFlexVar
        |> IO.andThen
            (\attrVar ->
                Type.mkFlexVar
                    |> IO.map
                        (\unifVar ->
                            let
                                attrType : Type
                                attrType =
                                    VarN attrVar

                                unifType : Type
                                unifType =
                                    VarN unifVar

                                shaderType : Type
                                shaderType =
                                    AppN ModuleName.webgl
                                        Name.shader
                                        [ toShaderRecord attributes attrType
                                        , toShaderRecord uniforms unifType
                                        , toShaderRecord varyings EmptyRecordN
                                        ]
                            in
                            Type.exists [ attrVar, unifVar ] (CEqual region Shader shaderType expected)
                        )
            )


{-| Non-recording Binop constraint (defensive; Binop nodes are dispatched to
the binop spine by `constrainWithIds`).
-}
constrainBinopNodeWithIds : RigidTypeVar -> A.Region -> Name -> Can.Annotation Name -> Can.Expr -> Can.Expr -> E.Expected Type -> IO Constraint
constrainBinopNodeWithIds rtv region op annotation leftExpr rightExpr expected =
    Type.mkFlexVar
        |> IO.andThen
            (\leftVar ->
                Type.mkFlexVar
                    |> IO.andThen
                        (\rightVar ->
                            Type.mkFlexVar
                                |> IO.andThen
                                    (\answerVar ->
                                        let
                                            leftType : Type
                                            leftType =
                                                VarN leftVar

                                            rightType : Type
                                            rightType =
                                                VarN rightVar

                                            answerType : Type
                                            answerType =
                                                VarN answerVar

                                            binopType : Type
                                            binopType =
                                                Type.funType leftType (Type.funType rightType answerType)

                                            opCon : Constraint
                                            opCon =
                                                CForeign region op annotation (NoExpectation binopType)
                                        in
                                        constrainWithIds rtv leftExpr (FromContext region (OpLeft op) leftType)
                                            |> IO.andThen
                                                (\leftCon ->
                                                    constrainWithIds rtv rightExpr (FromContext region (OpRight op) rightType)
                                                        |> IO.map
                                                            (\rightCon ->
                                                                Type.exists [ leftVar, rightVar, answerVar ]
                                                                    (CAnd
                                                                        [ opCon
                                                                        , leftCon
                                                                        , rightCon
                                                                        , CEqual region (CallResult (OpName op)) answerType expected
                                                                        ]
                                                                    )
                                                            )
                                                )
                                    )
                        )
            )


{-| Non-recording Call constraint (defensive; Call nodes are dispatched to
the call spine by `constrainWithIds`).
-}
constrainCallNodeWithIds : RigidTypeVar -> A.Region -> Can.Expr -> List Can.Expr -> E.Expected Type -> IO Constraint
constrainCallNodeWithIds rtv region ((A.At funcRegion _) as func) args expected =
    Type.mkFlexVar
        |> IO.andThen
            (\funcVar ->
                Type.mkFlexVar
                    |> IO.andThen
                        (\resultVar ->
                            let
                                level : CallLevel
                                level =
                                    { region = region
                                    , funcRegion = funcRegion
                                    , maybeName = getName func
                                    , funcVar = funcVar
                                    , resultVar = resultVar
                                    , funcType = VarN funcVar
                                    , resultType = VarN resultVar
                                    , numArgs = List.length args
                                    , expected = expected
                                    }
                            in
                            constrainWithIds rtv func (E.NoExpectation level.funcType)
                                |> IO.andThen
                                    (\funcCon ->
                                        constrainCallArgsWithIds rtv level Index.first args [] [] []
                                            |> IO.map
                                                (\( argVars, argTypes, argCons ) ->
                                                    assembleCall level funcCon argVars argTypes argCons
                                                )
                                    )
                        )
            )


{-| Non-recording If constraint (defensive; If nodes are dispatched to the
if spine by `constrainWithIds`).
-}
constrainIfNodeWithIds : RigidTypeVar -> A.Region -> List ( Can.Expr, Can.Expr ) -> Can.Expr -> E.Expected Type -> IO Constraint
constrainIfNodeWithIds rtv region branches finally expected =
    let
        boolExpect : Expected Type
        boolExpect =
            FromContext region IfCondition Type.bool

        ( conditions, exprs ) =
            List.foldr (\( c, e ) ( cs, es ) -> ( c :: cs, e :: es )) ( [], [ finally ] ) branches
    in
    constrainExprsWithIds rtv conditions boolExpect []
        |> IO.andThen
            (\condCons ->
                case expected of
                    FromAnnotation name arity _ tipe ->
                        constrainIndexedExprsWithIds rtv exprs (\index -> FromAnnotation name arity (TypedIfBranch index) tipe) Index.first []
                            |> IO.map (\branchCons -> CAnd (CAnd condCons :: branchCons))

                    _ ->
                        Type.mkFlexVar
                            |> IO.andThen
                                (\branchVar ->
                                    let
                                        branchType : Type
                                        branchType =
                                            VarN branchVar
                                    in
                                    constrainIndexedExprsWithIds rtv exprs (\index -> FromContext region (IfBranch index) branchType) Index.first []
                                        |> IO.map
                                            (\branchCons ->
                                                Type.exists [ branchVar ]
                                                    (CAnd
                                                        [ CAnd condCons
                                                        , CAnd branchCons
                                                        , CEqual region If branchType expected
                                                        ]
                                                    )
                                            )
                                )
            )


constrainExprsWithIds : RigidTypeVar -> List Can.Expr -> E.Expected Type -> List Constraint -> IO (List Constraint)
constrainExprsWithIds rtv exprs expected acc =
    case exprs of
        [] ->
            IO.pure (List.reverse acc)

        expr :: rest ->
            constrainWithIds rtv expr expected
                |> IO.andThen
                    (\con ->
                        constrainExprsWithIds rtv rest expected (con :: acc)
                    )


constrainIndexedExprsWithIds : RigidTypeVar -> List Can.Expr -> (Index.ZeroBased -> E.Expected Type) -> Index.ZeroBased -> List Constraint -> IO (List Constraint)
constrainIndexedExprsWithIds rtv exprs mkExpected index acc =
    case exprs of
        [] ->
            IO.pure (List.reverse acc)

        expr :: rest ->
            constrainWithIds rtv expr (mkExpected index)
                |> IO.andThen
                    (\con ->
                        constrainIndexedExprsWithIds rtv rest mkExpected (Index.next index) (con :: acc)
                    )



-- ====== CASE ======


constrainCaseWithIds : RigidTypeVar -> A.Region -> Int -> Can.Expr -> List Can.CaseBranch -> Expected Type -> IO Constraint
constrainCaseWithIds rtv region exprId expr branches expected =
    Type.mkFlexVar
        |> IO.andThen
            (\ptrnVar ->
                let
                    ptrnType : Type
                    ptrnType =
                        VarN ptrnVar

                    exprExpect : Expected Type
                    exprExpect =
                        NoExpectation ptrnType
                in
                case expected of
                    FromAnnotation name arity _ tipe ->
                        let
                            bodyExpect : Index.ZeroBased -> Expected Type
                            bodyExpect index =
                                FromAnnotation name arity (TypedCaseBranch index) tipe
                        in
                        -- Record ID with the expected type
                        (case tipe of
                            VarN v ->
                                -- Type is already a variable, just record it
                                NodeIds.recordNodeVar exprId v
                                    |> IO.map (\() -> Nothing)

                            _ ->
                                -- Type is concrete; create a flex var and constrain it to equal tipe
                                Type.mkFlexVar
                                    |> IO.andThen
                                        (\v ->
                                            NodeIds.recordNodeVar exprId v
                                                |> IO.map (\() -> Just v)
                                        )
                        )
                            |> IO.andThen
                                (\maybeCaseVar ->
                                    constrainWithIds rtv expr exprExpect
                                        |> IO.andThen
                                            (\exprCon ->
                                                constrainCaseBranchesWithIds rtv region ptrnType branches bodyExpect Index.first []
                                                    |> IO.map
                                                        (\branchCons ->
                                                            case maybeCaseVar of
                                                                Nothing ->
                                                                    -- tipe was VarN, no extra constraint needed
                                                                    Type.exists [ ptrnVar ] (CAnd (exprCon :: branchCons))

                                                                Just caseVar ->
                                                                    -- tipe was concrete, add constraint: caseVar = tipe
                                                                    Type.exists [ ptrnVar, caseVar ]
                                                                        (CAnd
                                                                            [ exprCon
                                                                            , CAnd branchCons
                                                                            , CEqual region Case (VarN caseVar) (NoExpectation tipe)
                                                                            ]
                                                                        )
                                                        )
                                            )
                                )

                    _ ->
                        Type.mkFlexVar
                            |> IO.andThen
                                (\branchVar ->
                                    -- Record branchVar for this case expression
                                    NodeIds.recordNodeVar exprId branchVar
                                        |> IO.andThen
                                            (\() ->
                                                let
                                                    branchType : Type
                                                    branchType =
                                                        VarN branchVar

                                                    bodyExpect : Index.ZeroBased -> Expected Type
                                                    bodyExpect index =
                                                        FromContext region (CaseBranch index) branchType
                                                in
                                                constrainWithIds rtv expr exprExpect
                                                    |> IO.andThen
                                                        (\exprCon ->
                                                            constrainCaseBranchesWithIds rtv region ptrnType branches bodyExpect Index.first []
                                                                |> IO.map
                                                                    (\branchCons ->
                                                                        Type.exists [ ptrnVar, branchVar ]
                                                                            (CAnd
                                                                                [ exprCon
                                                                                , CAnd branchCons
                                                                                , CEqual region Case branchType expected
                                                                                ]
                                                                            )
                                                                    )
                                                        )
                                            )
                                )
            )


{-| Non-recording Case constraint (defensive; Case nodes are dispatched to
`constrainCaseWithIds` by `constrainWithIds`).
-}
constrainCaseNodeWithIds : RigidTypeVar -> A.Region -> Can.Expr -> List Can.CaseBranch -> Expected Type -> IO Constraint
constrainCaseNodeWithIds rtv region expr branches expected =
    Type.mkFlexVar
        |> IO.andThen
            (\ptrnVar ->
                let
                    ptrnType : Type
                    ptrnType =
                        VarN ptrnVar

                    exprExpect : Expected Type
                    exprExpect =
                        NoExpectation ptrnType
                in
                case expected of
                    FromAnnotation name arity _ tipe ->
                        let
                            bodyExpect : Index.ZeroBased -> Expected Type
                            bodyExpect index =
                                FromAnnotation name arity (TypedCaseBranch index) tipe
                        in
                        constrainWithIds rtv expr exprExpect
                            |> IO.andThen
                                (\exprCon ->
                                    constrainCaseBranchesWithIds rtv region ptrnType branches bodyExpect Index.first []
                                        |> IO.map
                                            (\branchCons ->
                                                Type.exists [ ptrnVar ] (CAnd (exprCon :: branchCons))
                                            )
                                )

                    _ ->
                        Type.mkFlexVar
                            |> IO.andThen
                                (\branchVar ->
                                    let
                                        branchType : Type
                                        branchType =
                                            VarN branchVar

                                        bodyExpect : Index.ZeroBased -> Expected Type
                                        bodyExpect index =
                                            FromContext region (CaseBranch index) branchType
                                    in
                                    constrainWithIds rtv expr exprExpect
                                        |> IO.andThen
                                            (\exprCon ->
                                                constrainCaseBranchesWithIds rtv region ptrnType branches bodyExpect Index.first []
                                                    |> IO.map
                                                        (\branchCons ->
                                                            Type.exists [ ptrnVar, branchVar ]
                                                                (CAnd
                                                                    [ exprCon
                                                                    , CAnd branchCons
                                                                    , CEqual region Case branchType expected
                                                                    ]
                                                                )
                                                        )
                                            )
                                )
            )


constrainCaseBranchesWithIds : RigidTypeVar -> A.Region -> Type -> List Can.CaseBranch -> (Index.ZeroBased -> Expected Type) -> Index.ZeroBased -> List Constraint -> IO (List Constraint)
constrainCaseBranchesWithIds rtv region ptrnType branches mkExpected index acc =
    case branches of
        [] ->
            IO.pure (List.reverse acc)

        branch :: rest ->
            constrainCaseBranchWithIds rtv branch (PFromContext region (PCaseMatch index) ptrnType) (mkExpected index)
                |> IO.andThen
                    (\branchCon ->
                        constrainCaseBranchesWithIds rtv region ptrnType rest mkExpected (Index.next index) (branchCon :: acc)
                    )


constrainCaseBranchWithIds : RigidTypeVar -> Can.CaseBranch -> PExpected Type -> Expected Type -> IO Constraint
constrainCaseBranchWithIds rtv (Can.CaseBranch pattern expr) pExpect bExpect =
    Pattern.addWithIds pattern pExpect Common.emptyState
        |> IO.andThen
            (\(State headers pvars revCons) ->
                constrainWithIds rtv expr bExpect
                    |> IO.map
                        (\bodyCon ->
                            CLet [] pvars headers (CAnd (List.reverse revCons)) bodyCon
                        )
            )



-- ====== LAMBDA / LIST / TUPLE / RECORD / UPDATE / ACCESSOR / DESTRUCT ======


constrainLambdaWithIds : RigidTypeVar -> A.Region -> List Can.Pattern -> Can.Expr -> E.Expected Type -> IO Constraint
constrainLambdaWithIds rtv region args body expected =
    constrainArgsWithIds args
        |> IO.andThen
            (\props ->
                let
                    (State headers pvars revCons) =
                        props.state
                in
                constrainWithIds rtv body (NoExpectation props.result)
                    |> IO.map
                        (\bodyCon ->
                            Type.exists props.vars <|
                                CAnd
                                    [ CLet []
                                        pvars
                                        headers
                                        (CAnd (List.reverse revCons))
                                        bodyCon
                                    , CEqual region Lambda props.tipe expected
                                    ]
                        )
            )


constrainListWithIds : RigidTypeVar -> A.Region -> List Can.Expr -> E.Expected Type -> IO Constraint
constrainListWithIds rtv region entries expected =
    Type.mkFlexVar
        |> IO.andThen
            (\entryVar ->
                let
                    entryType : Type
                    entryType =
                        VarN entryVar

                    listType : Type
                    listType =
                        AppN ModuleName.list Name.list [ entryType ]
                in
                constrainListEntriesWithIds rtv region entryType Index.first entries []
                    |> IO.map
                        (\entryCons ->
                            Type.exists [ entryVar ]
                                (CAnd
                                    [ CAnd entryCons
                                    , CEqual region List listType expected
                                    ]
                                )
                        )
            )


constrainListEntriesWithIds : RigidTypeVar -> A.Region -> Type -> Index.ZeroBased -> List Can.Expr -> List Constraint -> IO (List Constraint)
constrainListEntriesWithIds rtv region tipe index entries acc =
    case entries of
        [] ->
            IO.pure (List.reverse acc)

        entry :: rest ->
            constrainWithIds rtv entry (FromContext region (ListEntry index) tipe)
                |> IO.andThen
                    (\entryCon ->
                        constrainListEntriesWithIds rtv region tipe (Index.next index) rest (entryCon :: acc)
                    )


constrainRecordWithIds : RigidTypeVar -> A.Region -> DMap.Dict String (A.Located Name) Can.Expr -> Expected Type -> IO Constraint
constrainRecordWithIds rtv region fields expected =
    let
        fieldList : List ( A.Located Name, Can.Expr )
        fieldList =
            DMap.toList A.compareLocated fields
    in
    constrainFieldsWithIds rtv fieldList []
        |> IO.map
            (\fieldResults ->
                let
                    dict : DMap.Dict String (A.Located Name) ( IO.Variable, Type, Constraint )
                    dict =
                        DMap.fromList A.toValue fieldResults

                    getTypeFromResult : a -> ( b, c, d ) -> c
                    getTypeFromResult _ ( _, t, _ ) =
                        t

                    recordType : Type
                    recordType =
                        RecordN (Utils.dictMapKeys A.compareLocated A.toValue (DMap.map getTypeFromResult dict)) EmptyRecordN

                    recordCon : Constraint
                    recordCon =
                        CEqual region Record recordType expected

                    vars : List IO.Variable
                    vars =
                        DMap.foldr A.compareLocated (\_ ( v, _, _ ) vs -> v :: vs) [] dict

                    cons : List Constraint
                    cons =
                        DMap.foldr A.compareLocated (\_ ( _, _, c ) cs -> c :: cs) [ recordCon ] dict
                in
                Type.exists vars (CAnd cons)
            )


constrainFieldsWithIds : RigidTypeVar -> List ( A.Located Name, Can.Expr ) -> List ( A.Located Name, ( IO.Variable, Type, Constraint ) ) -> IO (List ( A.Located Name, ( IO.Variable, Type, Constraint ) ))
constrainFieldsWithIds rtv fields acc =
    case fields of
        [] ->
            IO.pure (List.reverse acc)

        ( locName, expr ) :: rest ->
            Type.mkFlexVar
                |> IO.andThen
                    (\fieldVar ->
                        let
                            fieldType : Type
                            fieldType =
                                VarN fieldVar
                        in
                        constrainWithIds rtv expr (NoExpectation fieldType)
                            |> IO.andThen
                                (\fieldCon ->
                                    constrainFieldsWithIds rtv rest (( locName, ( fieldVar, fieldType, fieldCon ) ) :: acc)
                                )
                    )


constrainUpdateWithIds : RigidTypeVar -> A.Region -> Int -> Can.Expr -> DMap.Dict String (A.Located Name) Can.FieldUpdate -> Expected Type -> IO Constraint
constrainUpdateWithIds rtv region exprId expr locatedFields expected =
    Type.mkFlexVar
        |> IO.andThen
            (\extVar ->
                Type.mkFlexVar
                    |> IO.andThen
                        (\recordVar ->
                            -- Record recordVar for this update expression
                            NodeIds.recordNodeVar exprId recordVar
                                |> IO.andThen
                                    (\() ->
                                        let
                                            fields : Dict Name Can.FieldUpdate
                                            fields =
                                                DMap.foldl A.compareLocated (\k v acc -> Dict.insert (A.toValue k) v acc) Dict.empty locatedFields

                                            updateList : List ( Name, Can.FieldUpdate )
                                            updateList =
                                                Dict.toList fields
                                        in
                                        constrainUpdateFieldsWithIds rtv region updateList []
                                            |> IO.andThen
                                                (\fieldResults ->
                                                    let
                                                        fieldDict : Dict Name ( IO.Variable, Type, Constraint )
                                                        fieldDict =
                                                            Dict.fromList fieldResults

                                                        recordType : Type
                                                        recordType =
                                                            VarN recordVar

                                                        fieldsType : Type
                                                        fieldsType =
                                                            RecordN (Dict.map (\_ ( _, t, _ ) -> t) fieldDict) (VarN extVar)

                                                        fieldsCon : Constraint
                                                        fieldsCon =
                                                            CEqual region Record recordType (NoExpectation fieldsType)

                                                        recordCon : Constraint
                                                        recordCon =
                                                            CEqual region Record recordType expected

                                                        vars : List IO.Variable
                                                        vars =
                                                            Dict.foldr (\_ ( v, _, _ ) vs -> v :: vs) [ recordVar, extVar ] fieldDict

                                                        cons : List Constraint
                                                        cons =
                                                            Dict.foldr (\_ ( _, _, c ) cs -> c :: cs) [ recordCon ] fieldDict
                                                    in
                                                    constrainWithIds rtv expr (FromContext region (RecordUpdateKeys fields) recordType)
                                                        |> IO.map
                                                            (\exprCon ->
                                                                Type.exists vars (CAnd (fieldsCon :: exprCon :: cons))
                                                            )
                                                )
                                    )
                        )
            )


constrainUpdateFieldsWithIds : RigidTypeVar -> A.Region -> List ( Name, Can.FieldUpdate ) -> List ( Name, ( IO.Variable, Type, Constraint ) ) -> IO (List ( Name, ( IO.Variable, Type, Constraint ) ))
constrainUpdateFieldsWithIds rtv _ fields acc =
    case fields of
        [] ->
            IO.pure (List.reverse acc)

        ( name, Can.FieldUpdate fieldRegion expr ) :: rest ->
            Type.mkFlexVar
                |> IO.andThen
                    (\fieldVar ->
                        let
                            fieldType : Type
                            fieldType =
                                VarN fieldVar

                            expectation : Expected Type
                            expectation =
                                FromContext fieldRegion (RecordUpdateValue name) fieldType
                        in
                        constrainWithIds rtv expr expectation
                            |> IO.andThen
                                (\fieldCon ->
                                    constrainUpdateFieldsWithIds rtv fieldRegion rest (( name, ( fieldVar, fieldType, fieldCon ) ) :: acc)
                                )
                    )


constrainTupleWithIds : RigidTypeVar -> A.Region -> Can.Expr -> Can.Expr -> List Can.Expr -> Expected Type -> IO Constraint
constrainTupleWithIds rtv region a b cs expected =
    Type.mkFlexVar
        |> IO.andThen
            (\aVar ->
                Type.mkFlexVar
                    |> IO.andThen
                        (\bVar ->
                            let
                                aType : Type
                                aType =
                                    VarN aVar

                                bType : Type
                                bType =
                                    VarN bVar
                            in
                            constrainWithIds rtv a (NoExpectation aType)
                                |> IO.andThen
                                    (\aCon ->
                                        constrainWithIds rtv b (NoExpectation bType)
                                            |> IO.andThen
                                                (\bCon ->
                                                    constrainTupleRestWithIds rtv region cs [] []
                                                        |> IO.map
                                                            (\( cCons, cVars ) ->
                                                                let
                                                                    tupleType : Type
                                                                    tupleType =
                                                                        TupleN aType bType (List.map VarN cVars)

                                                                    tupleCon : Constraint
                                                                    tupleCon =
                                                                        CEqual region Tuple tupleType expected
                                                                in
                                                                Type.exists (aVar :: bVar :: cVars) (CAnd (aCon :: bCon :: cCons ++ [ tupleCon ]))
                                                            )
                                                )
                                    )
                        )
            )


constrainTupleRestWithIds : RigidTypeVar -> A.Region -> List Can.Expr -> List Constraint -> List IO.Variable -> IO ( List Constraint, List IO.Variable )
constrainTupleRestWithIds rtv _ cs accCons accVars =
    case cs of
        [] ->
            IO.pure ( List.reverse accCons, List.reverse accVars )

        ((A.At cRegion _) as c) :: rest ->
            Type.mkFlexVar
                |> IO.andThen
                    (\cVar ->
                        let
                            cType : Type
                            cType =
                                VarN cVar
                        in
                        constrainWithIds rtv c (NoExpectation cType)
                            |> IO.andThen
                                (\cCon ->
                                    constrainTupleRestWithIds rtv cRegion rest (cCon :: accCons) (cVar :: accVars)
                                )
                    )


constrainAccessorWithIds : A.Region -> Name -> Expected Type -> IO Constraint
constrainAccessorWithIds region field expected =
    Type.mkFlexVar
        |> IO.andThen
            (\extVar ->
                Type.mkFlexVar
                    |> IO.map
                        (\fieldVar ->
                            let
                                extType : Type
                                extType =
                                    VarN extVar

                                fieldType : Type
                                fieldType =
                                    VarN fieldVar

                                recordType : Type
                                recordType =
                                    RecordN (Dict.singleton field fieldType) extType
                            in
                            Type.exists [ fieldVar, extVar ] (CEqual region (Accessor field) (FunN recordType fieldType) expected)
                        )
            )


constrainDestructWithIds : RigidTypeVar -> A.Region -> Can.Pattern -> Can.Expr -> Constraint -> IO Constraint
constrainDestructWithIds rtv region pattern expr bodyCon =
    Type.mkFlexVar
        |> IO.andThen
            (\patternVar ->
                let
                    patternType : Type
                    patternType =
                        VarN patternVar
                in
                Pattern.addWithIds pattern (PNoExpectation patternType) Common.emptyState
                    |> IO.andThen
                        (\(State headers pvars revCons) ->
                            constrainWithIds rtv expr (FromContext region Destructure patternType)
                                |> IO.map
                                    (\exprCon ->
                                        CLet [] (patternVar :: pvars) headers (CAnd (List.reverse (exprCon :: revCons))) bodyCon
                                    )
                        )
            )
