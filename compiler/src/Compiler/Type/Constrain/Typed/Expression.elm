module Compiler.Type.Constrain.Typed.Expression exposing (constrainDefWithIds, constrainRecursiveDefsWithIds)

{-| Type checking a module starts by turning its canonical expressions into a
tree of `Constraint`s, which `Compiler.Type.Solve` then solves. This module
builds that tree for expressions and for local and top-level definitions, and
while it does so it can note which solver variable stands for each node's type,
so that every node's type can be read back after solving.

The same code serves both pathways. The typed pathway runs it with node
recording on; the erased pathway runs it with recording off, and then the
`NodeIds` operations it calls record nothing (`Compiler.Type.Constrain.Typed.NodeIds`
owns the record). The constraints differ only in the placeholders described
below, and check the same program either way.

An _expectation_ (`Expected`) is the type an expression must have together with
the reason it must have it, from which a type error is worded. A _rigid_ type
variable is one named in an annotation; `rtv`, passed to almost every function
here, maps those in scope to their types.


## Recording a node's variable

A _Group A_ node records a variable of its own with `NodeIds.recordNodeVar`.
These are the integer literal, negation, operator application, function
application, `if`, `case`, field access, record update, field accessor, list,
tuple, record, anonymous function and the three kinds of `let`. Most record a
fresh variable equated with the expectation; integer literals and negations
record their `number` variable, applications their result variable, and field
accesses their field variable. An `if` or `case` under a `FromAnnotation`
expectation records the expected type's own variable when that type is a bare
variable, and otherwise a fresh variable equated with it.

A _Group B_ node has no variable of its own: string, character, float and unit
literals, shaders, and every `Var*` reference. With recording on,
`constrainGenericWithIds` gives it a placeholder variable, recorded with
`NodeIds.recordSyntheticExprVar` and equated with the expectation.

A kernel reference with no `Compiler.Type.KernelIntrinsics` row contributes no
constraint of its own, so its type is bounded only by its context; one with a
row is checked against the row's annotation like a foreign function.


## Stack safety

The compiled compiler overflows its stack on deep enough recursion. Most
directions in which an expression nests are only as deep as written source,
and are walked by direct recursion. The directions that can grow with the size
of the data in a program are walked by _spines_ instead: the body of a `let`,
the operands of an operator chain, the function or last argument of an
application, the final branch of an `if`/`else if` ladder, and the record of a
field-access chain.

A spine is a self-tail-recursive function, which Elm compiles into a loop. It
descends the chain, at each level making and recording that level's variables
and pushing a _frame_, the level's remaining work. It constrains the first node
off the chain with `constrainWithIds`, then folds the frames back up, innermost
first, with `IO.foldM`, giving the constraint a direct recursion would give.
`DeepSpineStackSafetyTest` builds deep chains along these axes.

@docs constrainDefWithIds, constrainRecursiveDefsWithIds

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeVars as Vars
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
import Compiler.Type.KernelIntrinsics as KernelIntrinsics
import Compiler.Type.Type as Type exposing (Constraint(..), Type(..))
import Data.Map as DMap
import Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Main as Utils



-- ====== DEFINITIONS ======


{-| Builds the constraint for one non-recursive definition `def` whose scope is
`bodyCon`, the constraint of the code that can see it.

An unannotated definition gets fresh flexible variables for its arguments and
result, and its type is generalized in `bodyCon`. For an annotated definition,
each type variable of the annotation not already in `rtv` becomes a new rigid
variable, recorded with `NodeIds.recordSchemeBinders` under the definition's
name; the body is checked against the type left after one arrow per argument,
with a `FromAnnotation` expectation.

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
            IO.traverseMapWithKey identity (\k _ -> Type.nameToRigid k) (DMap.fromList identity (Dict.toList newNames))
                |> IO.andThen
                    (\newRigidsDMap ->
                        let
                            newRigids : Dict Name Vars.Variable
                            newRigids =
                                Dict.fromList (DMap.toList newRigidsDMap)

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


{-| Builds the constraint for a group of mutually recursive definitions `defs`
whose scope is `bodyCon`.

Every annotated definition's type is in scope for the whole group and the body.
The unannotated definitions are checked together against their own, not yet
generalized, types, and are generalized only for the annotated definitions and
`bodyCon`.

-}
constrainRecursiveDefsWithIds : RigidTypeVar -> List Can.Def -> Constraint -> IO Constraint
constrainRecursiveDefsWithIds rtv defs bodyCon =
    recDefsHelpWithIds rtv defs bodyCon (Info [] [] Dict.empty) (Info [] [] Dict.empty)


{-| Builds the constraint for `defs` after adding each one to `rigidInfo` (if
annotated) or `flexInfo` (if not), then nests the two groups around `bodyCon`
as `constrainRecursiveDefsWithIds` describes.

The flexible variables gathered so far are threaded into the next unannotated
definition's pattern state, so they are declared in that definition's
constraint. An annotated definition's constraint is wrapped in a `CLet` that
introduces its new rigid variables.

-}
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
                    IO.traverseMapWithKey identity (\k _ -> Type.nameToRigid k) (DMap.fromList identity (Dict.toList newNames))
                        |> IO.andThen
                            (\newRigidsDMap ->
                                let
                                    newRigids : Dict Name Vars.Variable
                                    newRigids =
                                        Dict.fromList (DMap.toList newRigidsDMap)

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
                                                                        defCon : Constraint
                                                                        defCon =
                                                                            CLet []
                                                                                pvars
                                                                                headers
                                                                                (CAnd (List.reverse revCons))
                                                                                exprCon

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


{-| Constrains the argument patterns of an unannotated function, giving each a
fresh type variable, and returns the function's type, its result variable and
the patterns' bindings and constraints.
-}
constrainArgsWithIds : List Can.Pattern -> IO Args
constrainArgsWithIds args =
    argsHelpWithIds args Common.emptyState


{-| Constrains `args` on top of the pattern `state`, as `constrainArgsWithIds`
does, ending the function type with a fresh result variable.
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


{-| Constrains the argument patterns of the annotated definition `name` against
their annotated types, and returns the function's type, the type left after the
arguments, and the patterns' bindings and constraints.
-}
constrainTypedArgsWithIds :
    Dict Name Type
    -> Name
    -> List ( Can.Pattern, Can.Type Name )
    -> Can.Type Name
    -> IO TypedArgs
constrainTypedArgsWithIds rtv name args srcResultType =
    typedArgsHelpWithIds rtv name Index.first args srcResultType Common.emptyState


{-| Constrains `args`, numbered from `index`, on top of the pattern `state`, as
`constrainTypedArgsWithIds` does.
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


{-| Builds the constraint that expression `expr` has the type `expected` asks for,
recording its node's variable as the module docstring describes.

Group A forms go to their own helpers, those that can nest down a spine axis
go to their spine; every other form goes to `constrainGenericWithIds`.

-}
constrainWithIds : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainWithIds rtv ((A.At region exprInfo) as expr) expected =
    case exprInfo.node of
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


{-| Builds the constraint for a Group B node.

With recording on, it makes a placeholder variable, records it with
`NodeIds.recordSyntheticExprVar`, and equates it with `expected` beside the
node's own constraint. With recording off it returns the node's own constraint
alone.

-}
constrainGenericWithIds : RigidTypeVar -> A.Region -> Can.ExprInfo -> E.Expected Type -> IO Constraint
constrainGenericWithIds rtv region info expected =
    IO.getNodeIds
        |> IO.andThen
            (\state ->
                if state.recording then
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
                    constrainNodeWithIds rtv region info.node expected
            )


{-| Builds the constraint for an integer literal: a fresh `number` variable,
recorded for the node and equated with `expected`.
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


{-| Builds the constraint for a negation: a fresh `number` variable, recorded for
the node, that the operand must have and that is equated with `expected`.
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


{-| The definitions of one `let` level, waiting for the constraint of its body.

`LetDef` is a single definition, `LetRecDefs` a recursive group, and
`LetDestructPat` a pattern with the expression it destructures.

-}
type LetPayload
    = LetDef Can.Def
    | LetRecDefs (List Can.Def)
    | LetDestructPat Can.Pattern Can.Expr


{-| One `let` level whose body is still to be constrained: its definitions, the
variable recorded for the node, and the expectation on the whole `let`.
-}
type alias LetFrame =
    { region : A.Region
    , exprVar : Vars.Variable
    , payload : LetPayload
    , expected : E.Expected Type
    }


{-| Builds the constraint for a chain of `let`s, nesting down the body, without
using stack for its length.

The innermost body is checked against the outermost expectation, as upstream
does, so a mismatch between a `let`'s body and what is expected of it is
reported at the body. Each level's fresh variable, recorded for its node, is
then bound to the type the level's expectation asks for; that equation only
binds a fresh variable, so it never fails and never reports.

-}
constrainLetSpine : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainLetSpine rtv expr expected s0 =
    let
        ( s1, ( leafCon, frames ) ) =
            letSpineGo rtv expr expected [] s0
    in
    IO.foldM (applyLetFrame rtv) leafCon frames s1


{-| Descends the `let` chain from `current`, recording a variable for each level
and pushing it onto `frames`, and returns the constraint of the first body that
is not a `let` together with the frames, innermost first.
-}
letSpineGo : RigidTypeVar -> Can.Expr -> E.Expected Type -> List LetFrame -> IO.State -> ( IO.State, ( Constraint, List LetFrame ) )
letSpineGo rtv ((A.At region exprInfo) as current) expected frames s0 =
    case exprInfo.node of
        Can.Let def body ->
            let
                ( s1, exprVar ) =
                    Type.mkFlexVar s0

                ( s2, () ) =
                    NodeIds.recordNodeVar exprInfo.id exprVar s1
            in
            letSpineGo rtv body expected ({ region = region, exprVar = exprVar, payload = LetDef def, expected = expected } :: frames) s2

        Can.LetRec defs body ->
            let
                ( s1, exprVar ) =
                    Type.mkFlexVar s0

                ( s2, () ) =
                    NodeIds.recordNodeVar exprInfo.id exprVar s1
            in
            letSpineGo rtv body expected ({ region = region, exprVar = exprVar, payload = LetRecDefs defs, expected = expected } :: frames) s2

        Can.LetDestruct pattern defExpr body ->
            let
                ( s1, exprVar ) =
                    Type.mkFlexVar s0

                ( s2, () ) =
                    NodeIds.recordNodeVar exprInfo.id exprVar s1
            in
            letSpineGo rtv body expected ({ region = region, exprVar = exprVar, payload = LetDestructPat pattern defExpr, expected = expected } :: frames) s2

        _ ->
            let
                ( s1, con ) =
                    constrainWithIds rtv current expected s0
            in
            ( s1, ( con, frames ) )


{-| Builds one `let` level's constraint around `bodyCon`: its definitions scope
over the body, and its variable is bound to the type the level's expectation
asks for.
-}
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
                        , CEqual frame.region Lambda (VarN frame.exprVar) (NoExpectation (expectedType frame.expected))
                        ]
                    )
            )


{-| The type an expectation asks for, whatever its origin.
-}
expectedType : E.Expected Type -> Type
expectedType expected =
    case expected of
        NoExpectation tipe ->
            tipe

        FromContext _ _ tipe ->
            tipe

        FromAnnotation _ _ _ tipe ->
            tipe



-- ====== BINOP SPINE ======


{-| What one operator application contributes to the constraint apart from its
operands: its variables, the constraint on the operator itself, and its
expectation.
-}
type alias BinopLevel =
    { region : A.Region
    , op : Name
    , opCon : Constraint
    , leftVar : Vars.Variable
    , rightVar : Vars.Variable
    , answerVar : Vars.Variable
    , answerType : Type
    , expected : E.Expected Type
    }


{-| One operator application waiting for the constraint of the operand the spine
descended into.

`BinopDeferRight` descended into the left operand and still has the right one
to constrain, with its expectation. `BinopLeftDone` descended into the right
operand and holds the left operand's constraint.

-}
type BinopFrame
    = BinopDeferRight BinopLevel Can.Expr (E.Expected Type)
    | BinopLeftDone BinopLevel Constraint


{-| Tells whether an expression is an operator application.
-}
isBinopNode : Can.Expr -> Bool
isBinopNode (A.At _ info) =
    case info.node of
        Can.Binop _ _ _ _ _ _ ->
            True

        _ ->
            False


{-| Builds one operator application's constraint from its level and its two
operand constraints: the operator's type is `left -> right -> answer`, and
`answer` must meet the expectation.
-}
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


{-| Builds the constraint for a chain of operator applications without using
stack for its length, whichever operand the chain nests down.

At each level the spine descends into the left operand when it is an operator
application, deferring the right; otherwise it constrains the left operand and
descends into the right one when that is an operator application. An
application whose operands are both operator applications constrains its right
operand by a fresh call to `constrainWithIds` on the way back up, which costs
stack.

-}
constrainBinopSpine : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainBinopSpine rtv expr expected s0 =
    let
        ( s1, ( leafCon, frames ) ) =
            binopSpineGo rtv expr expected [] s0
    in
    IO.foldM (applyBinopFrame rtv) leafCon frames s1


{-| Descends the operator chain from `current`, making and recording each level's
variables and pushing a frame, and returns the constraint of the innermost
level together with the frames, innermost first.
-}
binopSpineGo : RigidTypeVar -> Can.Expr -> E.Expected Type -> List BinopFrame -> IO.State -> ( IO.State, ( Constraint, List BinopFrame ) )
binopSpineGo rtv ((A.At region exprInfo) as current) expected frames s0 =
    case exprInfo.node of
        Can.Binop op _ _ annotation leftExpr rightExpr ->
            let
                ( s1, leftVar ) =
                    Type.mkFlexVar s0

                ( s2, rightVar ) =
                    Type.mkFlexVar s1

                ( s3, answerVar ) =
                    Type.mkFlexVar s2

                ( s4, () ) =
                    NodeIds.recordNodeVar exprInfo.id answerVar s3

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
                binopSpineGo rtv leftExpr leftExpected (BinopDeferRight level rightExpr rightExpected :: frames) s4

            else
                let
                    ( s5, leftCon ) =
                        constrainWithIds rtv leftExpr leftExpected s4
                in
                if isBinopNode rightExpr then
                    binopSpineGo rtv rightExpr rightExpected (BinopLeftDone level leftCon :: frames) s5

                else
                    let
                        ( s6, rightCon ) =
                            constrainWithIds rtv rightExpr rightExpected s5
                    in
                    ( s6, ( assembleBinop level leftCon rightCon, frames ) )

        _ ->
            -- Unreachable: the spine only enters/loops on Binop nodes.
            let
                ( s1, con ) =
                    constrainWithIds rtv current expected s0
            in
            ( s1, ( con, frames ) )


{-| Completes one operator application around `childCon`, the constraint of the
operand the spine descended into, constraining a deferred right operand first.
-}
applyBinopFrame : RigidTypeVar -> Constraint -> BinopFrame -> IO Constraint
applyBinopFrame rtv childCon frame =
    case frame of
        BinopDeferRight level rightExpr rightExpected ->
            constrainWithIds rtv rightExpr rightExpected
                |> IO.map (\rightCon -> assembleBinop level childCon rightCon)

        BinopLeftDone level leftCon ->
            IO.pure (assembleBinop level leftCon childCon)



-- ====== CALL SPINE ======


{-| What one function application contributes to the constraint apart from its
function and arguments: its variables, the name used in error messages, its
argument count, and its expectation.
-}
type alias CallLevel =
    { region : A.Region
    , funcRegion : A.Region
    , maybeName : MaybeName
    , funcVar : Vars.Variable
    , resultVar : Vars.Variable
    , funcType : Type
    , resultType : Type
    , numArgs : Int
    , expected : E.Expected Type
    }


{-| One function application waiting for the constraint of the part the spine
descended into.

`CallDeferArgs` descended into the function and still has all the arguments to
constrain. `CallLastArg` descended into the last argument and holds the
function's constraint and every earlier argument's variable, type and
constraint, then the last argument's variable and type.

-}
type CallFrame
    = CallDeferArgs CallLevel (List Can.Expr)
    | CallLastArg CallLevel Constraint (List Vars.Variable) (List Type) (List Constraint) Vars.Variable Type


{-| Tells whether an expression is a function application.
-}
isCallNode : Can.Expr -> Bool
isCallNode (A.At _ info) =
    case info.node of
        Can.Call _ _ ->
            True

        _ ->
            False


{-| Builds one function application's constraint from its level, the function's
constraint and the arguments' variables, types and constraints.

The function's type must be the arguments' types arrowed into the result type,
and the result type must meet the expectation.

-}
assembleCall : CallLevel -> Constraint -> List Vars.Variable -> List Type -> List Constraint -> Constraint
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


{-| Builds the constraint for a chain of function applications without using
stack for its length, nesting down either the function (`((f x) y) z`) or the
last argument (`f (g (h x))`).

At each level the spine descends into the function when it is an application,
deferring the arguments. Otherwise it constrains the function and the
arguments in order, and descends into the last argument when that is an
application.

-}
constrainCallSpine : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainCallSpine rtv expr expected s0 =
    let
        ( s1, ( leafCon, frames ) ) =
            callSpineGo rtv expr expected [] s0
    in
    IO.foldM (applyCallFrame rtv) leafCon frames s1


{-| The result of walking one application's arguments: either the level's
finished constraint, or the last argument to descend into, with its
expectation and the frame that completes the level.
-}
type CallArgsOutcome
    = CallArgsDone Constraint
    | CallArgsDescend Can.Expr (E.Expected Type) CallFrame


{-| Descends the application chain from `current`, making and recording each
level's variables and pushing a frame, and returns the constraint of the
innermost level together with the frames, innermost first.
-}
callSpineGo : RigidTypeVar -> Can.Expr -> E.Expected Type -> List CallFrame -> IO.State -> ( IO.State, ( Constraint, List CallFrame ) )
callSpineGo rtv ((A.At region exprInfo) as current) expected frames s0 =
    case exprInfo.node of
        Can.Call ((A.At funcRegion _) as func) args ->
            let
                ( s1, funcVar ) =
                    Type.mkFlexVar s0

                ( s2, resultVar ) =
                    Type.mkFlexVar s1

                ( s3, () ) =
                    NodeIds.recordNodeVar exprInfo.id resultVar s2

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
                callSpineGo rtv func (E.NoExpectation level.funcType) (CallDeferArgs level args :: frames) s3

            else
                let
                    ( s4, funcCon ) =
                        constrainWithIds rtv func (E.NoExpectation level.funcType) s3

                    ( s5, outcome ) =
                        callSpineArgsGo rtv level funcCon Index.first args [] [] [] s4
                in
                case outcome of
                    CallArgsDone con ->
                        ( s5, ( con, frames ) )

                    CallArgsDescend lastArg argExpected lastFrame ->
                        callSpineGo rtv lastArg argExpected (lastFrame :: frames) s5

        _ ->
            let
                ( s1, con ) =
                    constrainWithIds rtv current expected s0
            in
            ( s1, ( con, frames ) )


{-| Constrains the arguments `remaining`, numbered from `index`, after those
already accumulated, stopping at a last argument that is an application.
-}
callSpineArgsGo : RigidTypeVar -> CallLevel -> Constraint -> Index.ZeroBased -> List Can.Expr -> List Vars.Variable -> List Type -> List Constraint -> IO.State -> ( IO.State, CallArgsOutcome )
callSpineArgsGo rtv level funcCon index remaining accVars accTypes accCons s0 =
    case remaining of
        [] ->
            ( s0
            , CallArgsDone (assembleCall level funcCon (List.reverse accVars) (List.reverse accTypes) (List.reverse accCons))
            )

        [ lastArg ] ->
            let
                ( s1, argVar ) =
                    Type.mkFlexVar s0

                argType : Type
                argType =
                    VarN argVar

                argExpected : E.Expected Type
                argExpected =
                    FromContext level.region (CallArg level.maybeName index) argType
            in
            if isCallNode lastArg then
                ( s1
                , CallArgsDescend lastArg
                    argExpected
                    (CallLastArg level funcCon (List.reverse accVars) (List.reverse accTypes) (List.reverse accCons) argVar argType)
                )

            else
                let
                    ( s2, argCon ) =
                        constrainWithIds rtv lastArg argExpected s1
                in
                ( s2
                , CallArgsDone
                    (assembleCall level
                        funcCon
                        (List.reverse (argVar :: accVars))
                        (List.reverse (argType :: accTypes))
                        (List.reverse (argCon :: accCons))
                    )
                )

        arg :: rest ->
            let
                ( s1, argVar ) =
                    Type.mkFlexVar s0

                argType : Type
                argType =
                    VarN argVar

                ( s2, argCon ) =
                    constrainWithIds rtv arg (FromContext level.region (CallArg level.maybeName index) argType) s1
            in
            callSpineArgsGo rtv level funcCon (Index.next index) rest (argVar :: accVars) (argType :: accTypes) (argCon :: accCons) s2


{-| Completes one function application around `childCon`, the constraint of the
function or last argument the spine descended into.
-}
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


{-| Constrains `args`, numbered from `index`, each against a fresh variable, and
returns every argument's variable, type and constraint in order, after the
accumulated ones.
-}
constrainCallArgsWithIds :
    RigidTypeVar
    -> CallLevel
    -> Index.ZeroBased
    -> List Can.Expr
    -> List Vars.Variable
    -> List Type
    -> List Constraint
    -> IO ( List Vars.Variable, List Type, List Constraint )
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


{-| One `if` level waiting for the constraint of its final branch: the constraints
of its earlier branches, and the function that builds the level's constraint
from all its branch constraints.
-}
type alias IfFrame =
    { assemble : List Constraint -> Constraint
    , earlierBranchCons : List Constraint
    }


{-| Tells whether an expression is an `if`.
-}
isIfNode : Can.Expr -> Bool
isIfNode (A.At _ info) =
    case info.node of
        Can.If _ _ ->
            True

        _ ->
            False


{-| Builds the constraint for an `if`/`else if` ladder without using stack for its
length, nesting down the final `else` branch.

At each level it constrains the conditions as `Bool`, records the level's
variable, constrains the earlier branches in order, and descends into the
final branch when that is an `if`.

-}
constrainIfSpine : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainIfSpine rtv expr expected s0 =
    let
        ( s1, ( leafCon, frames ) ) =
            ifSpineGo rtv expr expected [] s0
    in
    IO.foldM applyIfFrame leafCon frames s1


{-| The result of walking one `if` level's branches: either the level's finished
constraint, or the final branch to descend into, with its expectation and the
frame that completes the level.
-}
type IfBranchesOutcome
    = IfBranchesDone Constraint
    | IfBranchesDescend Can.Expr (E.Expected Type) IfFrame


{-| Descends the `if` ladder from `current`, pushing a frame for each level, and
returns the constraint of the innermost level together with the frames,
innermost first.
-}
ifSpineGo : RigidTypeVar -> Can.Expr -> E.Expected Type -> List IfFrame -> IO.State -> ( IO.State, ( Constraint, List IfFrame ) )
ifSpineGo rtv ((A.At region exprInfo) as current) expected frames s0 =
    case exprInfo.node of
        Can.If branches finally ->
            let
                boolExpect : Expected Type
                boolExpect =
                    FromContext region IfCondition Type.bool

                ( conditions, exprs ) =
                    List.foldr (\( c, e ) ( cs, es ) -> ( c :: cs, e :: es )) ( [], [ finally ] ) branches

                ( s1, condCons ) =
                    constrainExprsWithIds rtv conditions boolExpect [] s0

                ( s2, ( mkExpected, assemble ) ) =
                    ifLevelExpectations region exprInfo.id condCons expected s1

                ( s3, outcome ) =
                    ifSpineBranchesGo rtv mkExpected assemble Index.first exprs [] s2
            in
            case outcome of
                IfBranchesDone con ->
                    ( s3, ( con, frames ) )

                IfBranchesDescend finalExpr fExpected fFrame ->
                    ifSpineGo rtv finalExpr fExpected (fFrame :: frames) s3

        _ ->
            let
                ( s1, con ) =
                    constrainWithIds rtv current expected s0
            in
            ( s1, ( con, frames ) )


{-| Constrains the branches `remaining`, numbered from `index`, stopping at a final
branch that is an `if`.
-}
ifSpineBranchesGo : RigidTypeVar -> (Index.ZeroBased -> E.Expected Type) -> (List Constraint -> Constraint) -> Index.ZeroBased -> List Can.Expr -> List Constraint -> IO.State -> ( IO.State, IfBranchesOutcome )
ifSpineBranchesGo rtv mkExpected assemble index remaining accCons s0 =
    case remaining of
        [] ->
            ( s0, IfBranchesDone (assemble (List.reverse accCons)) )

        [ finalExpr ] ->
            if isIfNode finalExpr then
                ( s0, IfBranchesDescend finalExpr (mkExpected index) { assemble = assemble, earlierBranchCons = List.reverse accCons } )

            else
                let
                    ( s1, con ) =
                        constrainWithIds rtv finalExpr (mkExpected index) s0
                in
                ( s1, IfBranchesDone (assemble (List.reverse (con :: accCons))) )

        branchExpr :: rest ->
            let
                ( s1, con ) =
                    constrainWithIds rtv branchExpr (mkExpected index) s0
            in
            ifSpineBranchesGo rtv mkExpected assemble (Index.next index) rest (con :: accCons) s1


{-| Returns the expectation for each branch of one `if` level, and the
closure that assembles the level's constraint once all its branch constraints
are known, for an `if` with node id `exprId` at `region` whose conditions gave
`condCons`, under `expected`. On the typed pathway it records the level's node
variable.

This is a separate, non-recursive function on purpose: the two closures it
returns outlive one step of `ifSpineGo`, and `ifSpineGo` is self-tail-recursive.
Elm's JavaScript backend compiles such a function into a `while` loop whose
parameters and `let` variables are reassigned on each step, and a closure
created inside the loop sees the variables, not their values at creation. Built
inside `ifSpineGo`, an outer level's `assemble` would read the innermost
level's `condCons` and `expected`: the outer conditions would be dropped and
the outer `if` tied to its own branch variable instead of its expectation.
Closures built here capture this function's own parameters, which nothing
reassigns.

-}
ifLevelExpectations : A.Region -> Int -> List Constraint -> E.Expected Type -> IO ( Index.ZeroBased -> E.Expected Type, List Constraint -> Constraint )
ifLevelExpectations region exprId condCons expected =
    case expected of
        FromAnnotation name arity _ tipe ->
            (case tipe of
                VarN v ->
                    NodeIds.recordNodeVar exprId v
                        |> IO.map (\() -> Nothing)

                _ ->
                    Type.mkFlexVar
                        |> IO.andThen
                            (\v ->
                                NodeIds.recordNodeVar exprId v
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
                        NodeIds.recordNodeVar exprId branchVar
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


{-| Completes one `if` level with `childCon`, the constraint of its final branch.
-}
applyIfFrame : Constraint -> IfFrame -> IO Constraint
applyIfFrame childCon frame =
    IO.pure (frame.assemble (frame.earlierBranchCons ++ [ childCon ]))



-- ====== ACCESS SPINE ======


{-| One field access waiting for the constraint of the record expression: its
field and variables, and its expectation.
-}
type alias AccessFrame =
    { region : A.Region
    , field : Name
    , fieldType : Type
    , fieldVar : Vars.Variable
    , extVar : Vars.Variable
    , expected : E.Expected Type
    }


{-| Builds the constraint for a chain of field accesses (`r.a.b.c`) without using
stack for its length, nesting down the record expression.

At each level the record expression must be a record with the field, and the
field's variable, recorded for the node, must meet the expectation.

-}
constrainAccessSpine : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint
constrainAccessSpine rtv expr expected s0 =
    let
        ( s1, ( leafCon, frames ) ) =
            accessSpineGo rtv expr expected [] s0
    in
    IO.foldM applyAccessFrame leafCon frames s1


{-| Descends the access chain from `current`, recording each level's field
variable and pushing a frame, and returns the constraint of the innermost
record expression together with the frames, innermost first.
-}
accessSpineGo : RigidTypeVar -> Can.Expr -> E.Expected Type -> List AccessFrame -> IO.State -> ( IO.State, ( Constraint, List AccessFrame ) )
accessSpineGo rtv ((A.At region exprInfo) as current) expected frames s0 =
    case exprInfo.node of
        Can.Access childExpr (A.At accessRegion field) ->
            let
                ( s1, extVar ) =
                    Type.mkFlexVar s0

                ( s2, fieldVar ) =
                    Type.mkFlexVar s1

                ( s3, () ) =
                    NodeIds.recordNodeVar exprInfo.id fieldVar s2

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
            accessSpineGo rtv
                childExpr
                (FromContext region context recordType)
                ({ region = region
                 , field = field
                 , fieldType = fieldType
                 , fieldVar = fieldVar
                 , extVar = extVar
                 , expected = expected
                 }
                    :: frames
                )
                s3

        _ ->
            let
                ( s1, con ) =
                    constrainWithIds rtv current expected s0
            in
            ( s1, ( con, frames ) )


{-| Completes one field access around `recordCon`, the constraint of its record
expression.
-}
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


{-| Builds the constraint for a field accessor function (`.field`), with a fresh
variable recorded for the node and equated with `expected`.
-}
constrainAccessorGroupAWithIds : A.Region -> Int -> Name -> E.Expected Type -> IO Constraint
constrainAccessorGroupAWithIds region exprId field expected =
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


{-| Builds the constraint for a list literal, with a fresh variable recorded for
the node and equated with `expected`.
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


{-| Builds the constraint for a tuple, with a fresh variable recorded for the
node and equated with `expected`.
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


{-| Builds the constraint for a record literal, with a fresh variable recorded
for the node and equated with `expected`.
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


{-| Builds the constraint for an anonymous function, with a fresh variable
recorded for the node and equated with `expected`.
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


{-| Returns the name a type error uses for the kernel function `name` of module
`home` under `prefix`, written in full as `Elm.Kernel.List.fromArray` so that
same-named kernels under the `Elm` and `Eco` prefixes are told apart.
-}
kernelErrorName : Name -> Name -> Name -> Name
kernelErrorName prefix home name =
    prefix ++ ".Kernel." ++ home ++ "." ++ name



-- ====== GROUP B NODE DISPATCH ======


{-| Builds a node's own constraint against `expected`, without recording a
variable for it.

Only the Group B forms reach it, from `constrainGenericWithIds`. A kernel
reference with a `Compiler.Type.KernelIntrinsics` row becomes a `CForeign` on
the row's annotation; one without a row contributes no constraint of its own.
The arms for the other forms are not reached; `Access` and `Update` there give
`CTrue`.

-}
constrainNodeWithIds : RigidTypeVar -> A.Region -> Can.Expr_ -> E.Expected Type -> IO Constraint
constrainNodeWithIds rtv region node expected =
    case node of
        Can.VarLocal name ->
            IO.pure (CLocal region name expected)

        Can.VarTopLevel _ name ->
            IO.pure (CLocal region name expected)

        Can.VarKernel prefix home name ->
            case KernelIntrinsics.lookup prefix home name of
                Just row ->
                    IO.pure (CForeign region (kernelErrorName prefix home name) row.annotation expected)

                Nothing ->
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

        Can.Access _ _ ->
            IO.pure CTrue

        Can.Update _ _ ->
            IO.pure CTrue

        Can.Record fields ->
            constrainRecordWithIds rtv region fields expected

        Can.Tuple a b cs ->
            constrainTupleWithIds rtv region a b cs expected

        Can.Shader _ types ->
            constrainShaderWithIds region types expected



-- ====== NODE HELPERS ======


{-| Builds the constraint that a GLSL shader literal has the `WebGL.Shader` type
made from its attribute, uniform and varying declarations, with the attribute
and uniform records left open.
-}
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


{-| Builds an operator application's constraint by direct recursion, without
recording; not reached, since `constrainWithIds` sends operator applications
to the spine.
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


{-| Builds a function application's constraint by direct recursion, without
recording; not reached, since `constrainWithIds` sends applications to the
spine.
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


{-| Builds an `if`'s constraint by direct recursion, without recording; not
reached, since `constrainWithIds` sends `if`s to the spine.
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


{-| Constrains each of `exprs` against the same `expected`, returning the
constraints in order after the reversed accumulator `acc`.
-}
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


{-| Constrains each of `exprs` against `mkExpected` of its position, counted
from `index`, returning the constraints in order after the reversed
accumulator `acc`.
-}
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


{-| Builds the constraint for a `case`: every pattern must match the scrutinee's
type, and every branch must meet `expected`.

Under a `FromAnnotation` expectation each branch is checked against the
expected type, keeping the `FromAnnotation` reason, and the node records the
expected type's own variable when that type is a bare variable, otherwise a
fresh variable equated with it.
Under any other expectation the branches share a fresh variable, recorded for
the node and equated with `expected`.

-}
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
                        (case tipe of
                            VarN v ->
                                NodeIds.recordNodeVar exprId v
                                    |> IO.map (\() -> Nothing)

                            _ ->
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
                                                                    Type.exists [ ptrnVar ] (CAnd (exprCon :: branchCons))

                                                                Just caseVar ->
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


{-| Builds a `case`'s constraint without recording; not reached, since
`constrainWithIds` sends `case`s to `constrainCaseWithIds`.
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


{-| Constrains each branch, counted from `index`, with its pattern expected to
have `ptrnType` and its body expected to meet `mkExpected` of its position.
-}
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


{-| Builds one branch's constraint: the pattern's bindings scope over the body.
-}
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


{-| Builds an anonymous function's own constraint: fresh variables for the
arguments and result, the arguments' bindings scoping over the body, and the
function type equated with `expected`.
-}
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


{-| Builds a list literal's own constraint: every entry has one fresh element type,
and the list of it is equated with `expected`.
-}
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


{-| Constrains each list entry, counted from `index`, to have the element type
`tipe`.
-}
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


{-| Builds a record literal's own constraint: each field gets a fresh variable,
and the closed record of those fields is equated with `expected`.
-}
constrainRecordWithIds : RigidTypeVar -> A.Region -> DMap.Dict String (A.Located Name) Can.Expr -> Expected Type -> IO Constraint
constrainRecordWithIds rtv region fields expected =
    let
        fieldList : List ( A.Located Name, Can.Expr )
        fieldList =
            DMap.toList fields
    in
    constrainFieldsWithIds rtv fieldList []
        |> IO.map
            (\fieldResults ->
                let
                    dict : DMap.Dict String (A.Located Name) ( Vars.Variable, Type, Constraint )
                    dict =
                        DMap.fromList A.toValue fieldResults

                    getTypeFromResult : a -> ( b, c, d ) -> c
                    getTypeFromResult _ ( _, t, _ ) =
                        t

                    recordType : Type
                    recordType =
                        RecordN (Utils.dictMapKeys A.toValue (DMap.map getTypeFromResult dict)) EmptyRecordN

                    recordCon : Constraint
                    recordCon =
                        CEqual region Record recordType expected

                    vars : List Vars.Variable
                    vars =
                        DMap.foldr (\_ ( v, _, _ ) vs -> v :: vs) [] dict

                    cons : List Constraint
                    cons =
                        DMap.foldr (\_ ( _, _, c ) cs -> c :: cs) [ recordCon ] dict
                in
                Type.exists vars (CAnd cons)
            )


{-| Constrains each field's value against a fresh variable, returning each field
with its variable, type and constraint, in order after the reversed
accumulator `acc`.
-}
constrainFieldsWithIds : RigidTypeVar -> List ( A.Located Name, Can.Expr ) -> List ( A.Located Name, ( Vars.Variable, Type, Constraint ) ) -> IO (List ( A.Located Name, ( Vars.Variable, Type, Constraint ) ))
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


{-| Builds the constraint for a record update.

The record being updated, the result and the variable recorded for the node
are one type, a record holding at least the updated fields, each with the type
of its new value. So an update cannot change a field's type.

-}
constrainUpdateWithIds : RigidTypeVar -> A.Region -> Int -> Can.Expr -> DMap.Dict String (A.Located Name) Can.FieldUpdate -> Expected Type -> IO Constraint
constrainUpdateWithIds rtv region exprId expr locatedFields expected =
    Type.mkFlexVar
        |> IO.andThen
            (\extVar ->
                Type.mkFlexVar
                    |> IO.andThen
                        (\recordVar ->
                            NodeIds.recordNodeVar exprId recordVar
                                |> IO.andThen
                                    (\() ->
                                        let
                                            fields : Dict Name Can.FieldUpdate
                                            fields =
                                                DMap.foldl (\k v acc -> Dict.insert (A.toValue k) v acc) Dict.empty locatedFields

                                            updateList : List ( Name, Can.FieldUpdate )
                                            updateList =
                                                Dict.toList fields
                                        in
                                        constrainUpdateFieldsWithIds rtv updateList []
                                            |> IO.andThen
                                                (\fieldResults ->
                                                    let
                                                        fieldDict : Dict Name ( Vars.Variable, Type, Constraint )
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

                                                        vars : List Vars.Variable
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


{-| Constrains each updated field's new value against a fresh variable, returning
each field with its variable, type and constraint, in order after the reversed
accumulator `acc`.
-}
constrainUpdateFieldsWithIds : RigidTypeVar -> List ( Name, Can.FieldUpdate ) -> List ( Name, ( Vars.Variable, Type, Constraint ) ) -> IO (List ( Name, ( Vars.Variable, Type, Constraint ) ))
constrainUpdateFieldsWithIds rtv fields acc =
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
                                    constrainUpdateFieldsWithIds rtv rest (( name, ( fieldVar, fieldType, fieldCon ) ) :: acc)
                                )
                    )


{-| Builds a tuple's own constraint: each element gets a fresh variable, and the
tuple of them is equated with `expected`.
-}
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
                                                    constrainTupleRestWithIds rtv cs [] []
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


{-| Constrains the tuple elements after the second against fresh variables,
returning their constraints and variables in order.
-}
constrainTupleRestWithIds : RigidTypeVar -> List Can.Expr -> List Constraint -> List Vars.Variable -> IO ( List Constraint, List Vars.Variable )
constrainTupleRestWithIds rtv cs accCons accVars =
    case cs of
        [] ->
            IO.pure ( List.reverse accCons, List.reverse accVars )

        ((A.At _ _) as c) :: rest ->
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
                                    constrainTupleRestWithIds rtv rest (cCon :: accCons) (cVar :: accVars)
                                )
                    )


{-| Builds a field accessor's own constraint: `.field` is a function from any
record with `field` to that field's type, equated with `expected`.
-}
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


{-| Builds the constraint for a destructuring `let` whose scope is `bodyCon`: the
expression must have the pattern's type, and the pattern's bindings scope over
`bodyCon`.
-}
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
