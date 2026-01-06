module Compiler.Type.Constrain.Erased.Expression exposing (constrainDef, constrainRecursiveDefs)

{-| Type constraint generation for expressions (Erased pathway).

This module walks through canonical expression AST nodes and generates type constraints
that will be solved during type inference. It handles all expression forms including
literals, variables, function calls, pattern matching, records, and more.

The constraint generation process creates relationships between types (e.g., "this
function argument must have the same type as this parameter") without immediately
solving them. The actual unification happens in a separate solving phase.


# Constraint Generation

@docs constrainDef, constrainRecursiveDefs

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E exposing (Category(..), Context(..), Expected(..), MaybeName(..), PContext(..), PExpected(..), SubContext(..))
import Compiler.Type.Constrain.Common as Common exposing (Args(..), Info(..), RigidTypeVar, State(..), TypedArgs(..), emptyInfo, getAccessName, getName, makeArgs, toShaderRecord)
import Compiler.Type.Constrain.Erased.Pattern as Pattern
import Compiler.Type.Constrain.Erased.Program as Prog exposing (Prog)
import Compiler.Type.Instantiate as Instantiate
import Compiler.Type.Type as Type exposing (Constraint(..), Type(..))
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Main as Utils



-- CONSTRAIN DEF


{-| Generate constraints for a single definition in a let-expression. Handles
both unannotated definitions (where types are inferred) and typed definitions
(where explicit type annotations guide constraint generation).

Uses the stack-safe DSL internally.

-}
constrainDef : RigidTypeVar -> Can.Def -> Constraint -> IO Constraint
constrainDef rtv def bodyCon =
    constrainDefProg rtv def bodyCon |> Prog.run



-- CONSTRAIN RECURSIVE DEFS


{-| Generate constraints for a group of mutually recursive definitions in a
let-rec expression. Handles both typed and untyped definitions, ensuring that
recursive references are properly constrained.

Uses the stack-safe DSL internally.

-}
constrainRecursiveDefs : RigidTypeVar -> List Can.Def -> Constraint -> IO Constraint
constrainRecursiveDefs rtv defs bodyCon =
    constrainRecursiveDefsProg rtv defs bodyCon |> Prog.run



-- ====== Stack-Safe DSL-Based Constraint Generation ======
--
-- These functions use the Program DSL to avoid stack overflow on deeply nested
-- expressions. The DSL represents constraint-generation steps as data that is
-- interpreted by a tail-recursive loop, keeping stack depth constant.


{-| Generate type constraints using the stack-safe DSL.

This is the main entry point for DSL-based constraint generation. It handles
all expression types and uses an explicit continuation stack to avoid growing
the JavaScript call stack proportionally to AST depth.

-}
constrainProg : RigidTypeVar -> Can.Expr -> E.Expected Type -> Prog Constraint
constrainProg rtv (A.At region exprInfo) expected =
    case exprInfo.node of
        -- Leaf cases: return immediately without recursion
        Can.VarLocal name ->
            Prog.pure (CLocal region name expected)

        Can.VarTopLevel _ name ->
            Prog.pure (CLocal region name expected)

        Can.VarKernel _ _ ->
            Prog.pure CTrue

        Can.VarForeign _ name annotation ->
            Prog.pure (CForeign region name annotation expected)

        Can.VarCtor _ _ name _ annotation ->
            Prog.pure (CForeign region name annotation expected)

        Can.VarDebug _ name annotation ->
            Prog.pure (CForeign region name annotation expected)

        Can.VarOperator op _ _ annotation ->
            Prog.pure (CForeign region op annotation expected)

        Can.Str _ ->
            Prog.pure (CEqual region String Type.string expected)

        Can.Chr _ ->
            Prog.pure (CEqual region Char Type.char expected)

        Can.Int _ ->
            Prog.opMkFlexNumber
                |> Prog.map
                    (\var ->
                        Type.exists [ var ] (CEqual region E.Number (VarN var) expected)
                    )

        Can.Float _ ->
            Prog.pure (CEqual region Float Type.float expected)

        Can.Unit ->
            Prog.pure (CEqual region Unit UnitN expected)

        -- Complex cases: delegate to specialized DSL builders
        Can.List elements ->
            constrainListProg rtv region elements expected

        Can.Negate expr ->
            constrainNegateProg rtv region expr expected

        Can.Binop op _ _ annotation leftExpr rightExpr ->
            constrainBinopProg rtv region op annotation leftExpr rightExpr expected

        Can.Lambda args body ->
            constrainLambdaProg rtv region args body expected

        Can.Call func args ->
            constrainCallProg rtv region func args expected

        Can.If branches finally ->
            constrainIfProg rtv region branches finally expected

        Can.Case expr branches ->
            constrainCaseProg rtv region expr branches expected

        Can.Let def body ->
            constrainProg rtv body expected
                |> Prog.andThen (constrainDefProg rtv def)

        Can.LetRec defs body ->
            constrainProg rtv body expected
                |> Prog.andThen (constrainRecursiveDefsProg rtv defs)

        Can.LetDestruct pattern expr body ->
            constrainProg rtv body expected
                |> Prog.andThen (constrainDestructProg rtv region pattern expr)

        Can.Accessor field ->
            constrainAccessorProg region field expected

        Can.Access expr (A.At accessRegion field) ->
            constrainAccessProg rtv region expr accessRegion field expected

        Can.Update expr fields ->
            constrainUpdateProg rtv region expr fields expected

        Can.Record fields ->
            constrainRecordProg rtv region fields expected

        Can.Tuple a b cs ->
            constrainTupleProg rtv region a b cs expected

        Can.Shader _ types ->
            constrainShaderProg region types expected



-- ====== DSL Builders for Recursive Cases ======


{-| DSL builder for binary operator expressions.
-}
constrainBinopProg : RigidTypeVar -> A.Region -> Name -> Can.Annotation -> Can.Expr -> Can.Expr -> E.Expected Type -> Prog Constraint
constrainBinopProg rtv region op annotation leftExpr rightExpr expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\leftVar ->
                Prog.opMkFlexVar
                    |> Prog.andThen
                        (\rightVar ->
                            Prog.opMkFlexVar
                                |> Prog.andThen
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
                                        constrainProg rtv leftExpr (FromContext region (OpLeft op) leftType)
                                            |> Prog.andThen
                                                (\leftCon ->
                                                    constrainProg rtv rightExpr (FromContext region (OpRight op) rightType)
                                                        |> Prog.map
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


{-| DSL builder for negation expressions.
-}
constrainNegateProg : RigidTypeVar -> A.Region -> Can.Expr -> E.Expected Type -> Prog Constraint
constrainNegateProg rtv region expr expected =
    Prog.opMkFlexNumber
        |> Prog.andThen
            (\numberVar ->
                let
                    numberType : Type
                    numberType =
                        VarN numberVar
                in
                constrainProg rtv expr (FromContext region Negate numberType)
                    |> Prog.map
                        (\numberCon ->
                            let
                                negateCon : Constraint
                                negateCon =
                                    CEqual region E.Number numberType expected
                            in
                            Type.exists [ numberVar ] (CAnd [ numberCon, negateCon ])
                        )
            )


{-| DSL builder for list expressions.
-}
constrainListProg : RigidTypeVar -> A.Region -> List Can.Expr -> E.Expected Type -> Prog Constraint
constrainListProg rtv region entries expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\entryVar ->
                let
                    entryType : Type
                    entryType =
                        VarN entryVar

                    listType : Type
                    listType =
                        AppN ModuleName.list Name.list [ entryType ]
                in
                constrainListEntriesProg rtv region entryType Index.first entries []
                    |> Prog.map
                        (\entryCons ->
                            Type.exists [ entryVar ]
                                (CAnd
                                    [ CAnd entryCons
                                    , CEqual region List listType expected
                                    ]
                                )
                        )
            )


constrainListEntriesProg : RigidTypeVar -> A.Region -> Type -> Index.ZeroBased -> List Can.Expr -> List Constraint -> Prog (List Constraint)
constrainListEntriesProg rtv region tipe index entries acc =
    case entries of
        [] ->
            Prog.pure (List.reverse acc)

        entry :: rest ->
            constrainProg rtv entry (FromContext region (ListEntry index) tipe)
                |> Prog.andThen
                    (\con ->
                        constrainListEntriesProg rtv region tipe (Index.next index) rest (con :: acc)
                    )


{-| DSL builder for if expressions.
-}
constrainIfProg : RigidTypeVar -> A.Region -> List ( Can.Expr, Can.Expr ) -> Can.Expr -> E.Expected Type -> Prog Constraint
constrainIfProg rtv region branches final expected =
    let
        boolExpect : Expected Type
        boolExpect =
            FromContext region IfCondition Type.bool

        ( conditions, exprs ) =
            List.foldr (\( c, e ) ( cs, es ) -> ( c :: cs, e :: es )) ( [], [ final ] ) branches
    in
    constrainExprsProg rtv conditions boolExpect []
        |> Prog.andThen
            (\condCons ->
                case expected of
                    FromAnnotation name arity _ tipe ->
                        constrainIndexedExprsProg rtv exprs (\index -> FromAnnotation name arity (TypedIfBranch index) tipe) Index.first []
                            |> Prog.map
                                (\branchCons ->
                                    CAnd (CAnd condCons :: branchCons)
                                )

                    _ ->
                        Prog.opMkFlexVar
                            |> Prog.andThen
                                (\branchVar ->
                                    let
                                        branchType : Type
                                        branchType =
                                            VarN branchVar
                                    in
                                    constrainIndexedExprsProg rtv exprs (\index -> FromContext region (IfBranch index) branchType) Index.first []
                                        |> Prog.map
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


constrainExprsProg : RigidTypeVar -> List Can.Expr -> E.Expected Type -> List Constraint -> Prog (List Constraint)
constrainExprsProg rtv exprs expected acc =
    case exprs of
        [] ->
            Prog.pure (List.reverse acc)

        expr :: rest ->
            constrainProg rtv expr expected
                |> Prog.andThen
                    (\con ->
                        constrainExprsProg rtv rest expected (con :: acc)
                    )


constrainIndexedExprsProg : RigidTypeVar -> List Can.Expr -> (Index.ZeroBased -> E.Expected Type) -> Index.ZeroBased -> List Constraint -> Prog (List Constraint)
constrainIndexedExprsProg rtv exprs mkExpected index acc =
    case exprs of
        [] ->
            Prog.pure (List.reverse acc)

        expr :: rest ->
            constrainProg rtv expr (mkExpected index)
                |> Prog.andThen
                    (\con ->
                        constrainIndexedExprsProg rtv rest mkExpected (Index.next index) (con :: acc)
                    )


{-| DSL builder for case expressions.
-}
constrainCaseProg : RigidTypeVar -> A.Region -> Can.Expr -> List Can.CaseBranch -> Expected Type -> Prog Constraint
constrainCaseProg rtv region expr branches expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\ptrnVar ->
                let
                    ptrnType : Type
                    ptrnType =
                        VarN ptrnVar
                in
                constrainProg rtv expr (NoExpectation ptrnType)
                    |> Prog.andThen
                        (\exprCon ->
                            case expected of
                                FromAnnotation name arity _ tipe ->
                                    constrainCaseBranchesProg rtv region ptrnType branches (\index -> FromAnnotation name arity (TypedCaseBranch index) tipe) Index.first []
                                        |> Prog.map
                                            (\branchCons ->
                                                Type.exists [ ptrnVar ] (CAnd (exprCon :: branchCons))
                                            )

                                _ ->
                                    Prog.opMkFlexVar
                                        |> Prog.andThen
                                            (\branchVar ->
                                                let
                                                    branchType : Type
                                                    branchType =
                                                        VarN branchVar
                                                in
                                                constrainCaseBranchesProg rtv region ptrnType branches (\index -> FromContext region (CaseBranch index) branchType) Index.first []
                                                    |> Prog.map
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


constrainCaseBranchesProg : RigidTypeVar -> A.Region -> Type -> List Can.CaseBranch -> (Index.ZeroBased -> Expected Type) -> Index.ZeroBased -> List Constraint -> Prog (List Constraint)
constrainCaseBranchesProg rtv region ptrnType branches mkExpected index acc =
    case branches of
        [] ->
            Prog.pure (List.reverse acc)

        branch :: rest ->
            constrainCaseBranchProg rtv branch (PFromContext region (PCaseMatch index) ptrnType) (mkExpected index)
                |> Prog.andThen
                    (\con ->
                        constrainCaseBranchesProg rtv region ptrnType rest mkExpected (Index.next index) (con :: acc)
                    )


constrainCaseBranchProg : RigidTypeVar -> Can.CaseBranch -> PExpected Type -> Expected Type -> Prog Constraint
constrainCaseBranchProg rtv (Can.CaseBranch pattern expr) pExpect bExpect =
    Prog.opIO (Pattern.add pattern pExpect Common.emptyState)
        |> Prog.andThen
            (\(State headers pvars revCons) ->
                constrainProg rtv expr bExpect
                    |> Prog.map (CLet [] pvars headers (CAnd (List.reverse revCons)))
            )


{-| DSL builder for lambda expressions.
-}
constrainLambdaProg : RigidTypeVar -> A.Region -> List Can.Pattern -> Can.Expr -> E.Expected Type -> Prog Constraint
constrainLambdaProg rtv region args body expected =
    constrainArgsProg args Common.emptyState
        |> Prog.andThen
            (\(Args props) ->
                let
                    (State headers pvars revCons) =
                        props.state
                in
                constrainProg rtv body (NoExpectation props.result)
                    |> Prog.map
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


constrainArgsProg : List Can.Pattern -> State -> Prog Args
constrainArgsProg args state =
    case args of
        [] ->
            Prog.opMkFlexVar
                |> Prog.map
                    (\resultVar ->
                        let
                            resultType : Type
                            resultType =
                                VarN resultVar
                        in
                        makeArgs [ resultVar ] resultType resultType state
                    )

        pattern :: otherArgs ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        Prog.opIO (Pattern.add pattern (PNoExpectation argType) state)
                            |> Prog.andThen (constrainArgsProg otherArgs)
                            |> Prog.map
                                (\(Args props) ->
                                    makeArgs (argVar :: props.vars) (FunN argType props.tipe) props.result props.state
                                )
                    )


argsHelpProg : List Can.Pattern -> State -> Prog Args
argsHelpProg args state =
    case args of
        [] ->
            Prog.opMkFlexVar
                |> Prog.map
                    (\resultVar ->
                        let
                            resultType : Type
                            resultType =
                                VarN resultVar
                        in
                        makeArgs [ resultVar ] resultType resultType state
                    )

        pattern :: otherArgs ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        Prog.opIO (Pattern.add pattern (PNoExpectation argType) state)
                            |> Prog.andThen (argsHelpProg otherArgs)
                            |> Prog.map
                                (\(Args props) ->
                                    makeArgs (argVar :: props.vars) (FunN argType props.tipe) props.result props.state
                                )
                    )


{-| DSL builder for function call expressions.
-}
constrainCallProg : RigidTypeVar -> A.Region -> Can.Expr -> List Can.Expr -> E.Expected Type -> Prog Constraint
constrainCallProg rtv region ((A.At funcRegion _) as func) args expected =
    let
        maybeName : MaybeName
        maybeName =
            getName func
    in
    Prog.opMkFlexVar
        |> Prog.andThen
            (\funcVar ->
                Prog.opMkFlexVar
                    |> Prog.andThen
                        (\resultVar ->
                            let
                                funcType : Type
                                funcType =
                                    VarN funcVar

                                resultType : Type
                                resultType =
                                    VarN resultVar
                            in
                            constrainProg rtv func (E.NoExpectation funcType)
                                |> Prog.andThen
                                    (\funcCon ->
                                        constrainCallArgsProg rtv region maybeName Index.first args [] [] []
                                            |> Prog.map
                                                (\( argVars, argTypes, argCons ) ->
                                                    let
                                                        arityType : Type
                                                        arityType =
                                                            List.foldr FunN resultType argTypes

                                                        category : Category
                                                        category =
                                                            CallResult maybeName
                                                    in
                                                    Type.exists (funcVar :: resultVar :: argVars)
                                                        (CAnd
                                                            [ funcCon
                                                            , CEqual funcRegion category funcType (FromContext region (CallArity maybeName (List.length args)) arityType)
                                                            , CAnd argCons
                                                            , CEqual region category resultType expected
                                                            ]
                                                        )
                                                )
                                    )
                        )
            )


constrainCallArgsProg : RigidTypeVar -> A.Region -> E.MaybeName -> Index.ZeroBased -> List Can.Expr -> List IO.Variable -> List Type -> List Constraint -> Prog ( List IO.Variable, List Type, List Constraint )
constrainCallArgsProg rtv region maybeName index args accVars accTypes accCons =
    case args of
        [] ->
            Prog.pure ( List.reverse accVars, List.reverse accTypes, List.reverse accCons )

        arg :: rest ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        constrainProg rtv arg (FromContext region (CallArg maybeName index) argType)
                            |> Prog.andThen
                                (\argCon ->
                                    constrainCallArgsProg rtv region maybeName (Index.next index) rest (argVar :: accVars) (argType :: accTypes) (argCon :: accCons)
                                )
                    )


{-| DSL builder for record expressions.
-}
constrainRecordProg : RigidTypeVar -> A.Region -> Dict String (A.Located Name) Can.Expr -> Expected Type -> Prog Constraint
constrainRecordProg rtv region fields expected =
    constrainFieldsProg rtv (Dict.toList A.compareLocated fields) []
        |> Prog.map
            (\fieldResults ->
                let
                    dict : Dict String (A.Located Name) ( IO.Variable, Type, Constraint )
                    dict =
                        Dict.fromList A.toValue fieldResults

                    getTypeFromResult : a -> ( b, c, d ) -> c
                    getTypeFromResult _ ( _, t, _ ) =
                        t

                    recordType : Type
                    recordType =
                        RecordN (Utils.mapMapKeys identity A.compareLocated A.toValue (Dict.map getTypeFromResult dict)) EmptyRecordN

                    recordCon : Constraint
                    recordCon =
                        CEqual region Record recordType expected

                    vars : List IO.Variable
                    vars =
                        Dict.foldr A.compareLocated (\_ ( v, _, _ ) vs -> v :: vs) [] dict

                    cons : List Constraint
                    cons =
                        Dict.foldr A.compareLocated (\_ ( _, _, c ) cs -> c :: cs) [ recordCon ] dict
                in
                Type.exists vars (CAnd cons)
            )


constrainFieldsProg : RigidTypeVar -> List ( A.Located Name, Can.Expr ) -> List ( A.Located Name, ( IO.Variable, Type, Constraint ) ) -> Prog (List ( A.Located Name, ( IO.Variable, Type, Constraint ) ))
constrainFieldsProg rtv fields acc =
    case fields of
        [] ->
            Prog.pure (List.reverse acc)

        ( name, expr ) :: rest ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\var ->
                        let
                            tipe : Type
                            tipe =
                                VarN var
                        in
                        constrainProg rtv expr (NoExpectation tipe)
                            |> Prog.andThen
                                (\con ->
                                    constrainFieldsProg rtv rest (( name, ( var, tipe, con ) ) :: acc)
                                )
                    )


{-| DSL builder for record update expressions.
-}
constrainUpdateProg : RigidTypeVar -> A.Region -> Can.Expr -> Dict String (A.Located Name) Can.FieldUpdate -> Expected Type -> Prog Constraint
constrainUpdateProg rtv region expr locatedFields expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\extVar ->
                let
                    fields : Dict String Name Can.FieldUpdate
                    fields =
                        Utils.mapMapKeys identity A.compareLocated A.toValue locatedFields
                in
                constrainUpdateFieldsProg rtv region (Dict.toList compare fields) []
                    |> Prog.andThen
                        (\fieldResults ->
                            let
                                fieldDict : Dict String Name ( IO.Variable, Type, Constraint )
                                fieldDict =
                                    Dict.fromList identity fieldResults
                            in
                            Prog.opMkFlexVar
                                |> Prog.andThen
                                    (\recordVar ->
                                        let
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
                                                Dict.foldr compare (\_ ( v, _, _ ) vs -> v :: vs) [ recordVar, extVar ] fieldDict

                                            cons : List Constraint
                                            cons =
                                                Dict.foldr compare (\_ ( _, _, c ) cs -> c :: cs) [ recordCon ] fieldDict
                                        in
                                        constrainProg rtv expr (FromContext region (RecordUpdateKeys fields) recordType)
                                            |> Prog.map (\con -> Type.exists vars (CAnd (fieldsCon :: con :: cons)))
                                    )
                        )
            )


constrainUpdateFieldsProg : RigidTypeVar -> A.Region -> List ( Name, Can.FieldUpdate ) -> List ( Name, ( IO.Variable, Type, Constraint ) ) -> Prog (List ( Name, ( IO.Variable, Type, Constraint ) ))
constrainUpdateFieldsProg rtv region fields acc =
    case fields of
        [] ->
            Prog.pure (List.reverse acc)

        ( name, Can.FieldUpdate _ expr ) :: rest ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\var ->
                        let
                            tipe : Type
                            tipe =
                                VarN var
                        in
                        constrainProg rtv expr (FromContext region (RecordUpdateValue name) tipe)
                            |> Prog.andThen
                                (\con ->
                                    constrainUpdateFieldsProg rtv region rest (( name, ( var, tipe, con ) ) :: acc)
                                )
                    )


{-| DSL builder for tuple expressions.
-}
constrainTupleProg : RigidTypeVar -> A.Region -> Can.Expr -> Can.Expr -> List Can.Expr -> Expected Type -> Prog Constraint
constrainTupleProg rtv region a b cs expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\aVar ->
                Prog.opMkFlexVar
                    |> Prog.andThen
                        (\bVar ->
                            let
                                aType : Type
                                aType =
                                    VarN aVar

                                bType : Type
                                bType =
                                    VarN bVar
                            in
                            constrainProg rtv a (NoExpectation aType)
                                |> Prog.andThen
                                    (\aCon ->
                                        constrainProg rtv b (NoExpectation bType)
                                            |> Prog.andThen
                                                (\bCon ->
                                                    constrainTupleRestProg rtv cs [] []
                                                        |> Prog.map
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


constrainTupleRestProg : RigidTypeVar -> List Can.Expr -> List Constraint -> List IO.Variable -> Prog ( List Constraint, List IO.Variable )
constrainTupleRestProg rtv cs accCons accVars =
    case cs of
        [] ->
            Prog.pure ( List.reverse accCons, List.reverse accVars )

        c :: rest ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\cVar ->
                        constrainProg rtv c (NoExpectation (VarN cVar))
                            |> Prog.andThen
                                (\cCon ->
                                    constrainTupleRestProg rtv rest (cCon :: accCons) (cVar :: accVars)
                                )
                    )


{-| DSL builder for accessor expressions (.field).
-}
constrainAccessorProg : A.Region -> Name -> Expected Type -> Prog Constraint
constrainAccessorProg region field expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\extVar ->
                Prog.opMkFlexVar
                    |> Prog.map
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
                                    RecordN (Dict.singleton identity field fieldType) extType
                            in
                            Type.exists [ fieldVar, extVar ] (CEqual region (Accessor field) (FunN recordType fieldType) expected)
                        )
            )


{-| DSL builder for access expressions (expr.field).
-}
constrainAccessProg : RigidTypeVar -> A.Region -> Can.Expr -> A.Region -> Name -> Expected Type -> Prog Constraint
constrainAccessProg rtv region expr accessRegion field expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\extVar ->
                Prog.opMkFlexVar
                    |> Prog.andThen
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
                                    RecordN (Dict.singleton identity field fieldType) extType

                                context : Context
                                context =
                                    RecordAccess (A.toRegion expr) (getAccessName expr) accessRegion field
                            in
                            constrainProg rtv expr (FromContext region context recordType)
                                |> Prog.map
                                    (\recordCon ->
                                        Type.exists [ fieldVar, extVar ] (CAnd [ recordCon, CEqual region (Access field) fieldType expected ])
                                    )
                        )
            )


{-| DSL builder for shader expressions.
-}
constrainShaderProg : A.Region -> Shader.Types -> Expected Type -> Prog Constraint
constrainShaderProg region (Shader.Types attributes uniforms varyings) expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\attrVar ->
                Prog.opMkFlexVar
                    |> Prog.map
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


{-| DSL builder for destructure expressions.
-}
constrainDestructProg : RigidTypeVar -> A.Region -> Can.Pattern -> Can.Expr -> Constraint -> Prog Constraint
constrainDestructProg rtv region pattern expr bodyCon =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\patternVar ->
                let
                    patternType : Type
                    patternType =
                        VarN patternVar
                in
                Prog.opIO (Pattern.add pattern (PNoExpectation patternType) Common.emptyState)
                    |> Prog.andThen
                        (\(State headers pvars revCons) ->
                            constrainProg rtv expr (FromContext region Destructure patternType)
                                |> Prog.map
                                    (\exprCon ->
                                        CLet [] (patternVar :: pvars) headers (CAnd (List.reverse (exprCon :: revCons))) bodyCon
                                    )
                        )
            )


{-| DSL builder for single definition.
-}
constrainDefProg : RigidTypeVar -> Can.Def -> Constraint -> Prog Constraint
constrainDefProg rtv def bodyCon =
    case def of
        Can.Def (A.At region name) args expr ->
            constrainArgsProg args Common.emptyState
                |> Prog.andThen
                    (\(Args props) ->
                        let
                            (State headers pvars revCons) =
                                props.state
                        in
                        constrainProg rtv expr (NoExpectation props.result)
                            |> Prog.map
                                (\exprCon ->
                                    CLet []
                                        props.vars
                                        (Dict.singleton identity name (A.At region props.tipe))
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
                newNames : Dict String Name ()
                newNames =
                    Dict.diff freeVars rtv
            in
            Prog.opIO (IO.traverseMapWithKey identity compare (\n _ -> Type.nameToRigid n) newNames)
                |> Prog.andThen
                    (\newRigids ->
                        let
                            newRtv : Dict String Name Type
                            newRtv =
                                Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                        in
                        constrainTypedArgsProg newRtv name typedArgs srcResultType
                            |> Prog.andThen
                                (\(TypedArgs tipe resultType (State headers pvars revCons)) ->
                                    let
                                        expected : Expected Type
                                        expected =
                                            FromAnnotation name (List.length typedArgs) TypedBody resultType
                                    in
                                    constrainProg newRtv expr expected
                                        |> Prog.map
                                            (\exprCon ->
                                                CLet (Dict.values compare newRigids)
                                                    []
                                                    (Dict.singleton identity name (A.At region tipe))
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


constrainTypedArgsProg : Dict String Name Type -> Name -> List ( Can.Pattern, Can.Type ) -> Can.Type -> Prog TypedArgs
constrainTypedArgsProg rtv name args srcResultType =
    typedArgsHelpProg rtv name Index.first args srcResultType Common.emptyState


typedArgsHelpProg : Dict String Name Type -> Name -> Index.ZeroBased -> List ( Can.Pattern, Can.Type ) -> Can.Type -> State -> Prog TypedArgs
typedArgsHelpProg rtv name index args srcResultType state =
    case args of
        [] ->
            Prog.opIO (Instantiate.fromSrcType rtv srcResultType)
                |> Prog.map
                    (\resultType ->
                        TypedArgs resultType resultType state
                    )

        ( (A.At region _) as pattern, srcType ) :: otherArgs ->
            Prog.opIO (Instantiate.fromSrcType rtv srcType)
                |> Prog.andThen
                    (\argType ->
                        let
                            expected : PExpected Type
                            expected =
                                PFromContext region (PTypedArg name index) argType
                        in
                        Prog.opIO (Pattern.add pattern expected state)
                            |> Prog.andThen (typedArgsHelpProg rtv name (Index.next index) otherArgs srcResultType)
                            |> Prog.map
                                (\(TypedArgs tipe resultType newState) ->
                                    TypedArgs (FunN argType tipe) resultType newState
                                )
                    )


{-| DSL builder for recursive definitions.
-}
constrainRecursiveDefsProg : RigidTypeVar -> List Can.Def -> Constraint -> Prog Constraint
constrainRecursiveDefsProg rtv defs bodyCon =
    recDefsHelpProg rtv defs bodyCon emptyInfo emptyInfo


recDefsHelpProg : RigidTypeVar -> List Can.Def -> Constraint -> Info -> Info -> Prog Constraint
recDefsHelpProg rtv defs bodyCon rigidInfo flexInfo =
    case defs of
        [] ->
            let
                (Info rigidVars rigidCons rigidHeaders) =
                    rigidInfo

                (Info flexVars flexCons flexHeaders) =
                    flexInfo
            in
            Prog.pure
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
                    argsHelpProg args (State Dict.empty flexVars [])
                        |> Prog.andThen
                            (\(Args props) ->
                                let
                                    (State headers pvars revCons) =
                                        props.state
                                in
                                constrainProg rtv expr (NoExpectation props.result)
                                    |> Prog.andThen
                                        (\exprCon ->
                                            let
                                                defCon : Constraint
                                                defCon =
                                                    CLet []
                                                        pvars
                                                        headers
                                                        (CAnd (List.reverse revCons))
                                                        exprCon
                                            in
                                            recDefsHelpProg rtv otherDefs bodyCon rigidInfo <|
                                                Info props.vars
                                                    (defCon :: flexCons)
                                                    (Dict.insert identity name (A.At region props.tipe) flexHeaders)
                                        )
                            )

                Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
                    let
                        newNames : Dict String Name ()
                        newNames =
                            Dict.diff freeVars rtv
                    in
                    Prog.opIO (IO.traverseMapWithKey identity compare (\n _ -> Type.nameToRigid n) newNames)
                        |> Prog.andThen
                            (\newRigids ->
                                let
                                    newRtv : Dict String Name Type
                                    newRtv =
                                        Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                                in
                                constrainTypedArgsProg newRtv name typedArgs srcResultType
                                    |> Prog.andThen
                                        (\(TypedArgs tipe resultType (State headers pvars revCons)) ->
                                            constrainProg newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType)
                                                |> Prog.andThen
                                                    (\exprCon ->
                                                        let
                                                            defCon : Constraint
                                                            defCon =
                                                                CLet []
                                                                    pvars
                                                                    headers
                                                                    (CAnd (List.reverse revCons))
                                                                    exprCon

                                                            (Info rigidVars rigidCons rigidHeaders) =
                                                                rigidInfo
                                                        in
                                                        recDefsHelpProg rtv
                                                            otherDefs
                                                            bodyCon
                                                            (Info
                                                                (Dict.foldr compare (\_ -> (::)) rigidVars newRigids)
                                                                (CLet (Dict.values compare newRigids) [] Dict.empty defCon CTrue :: rigidCons)
                                                                (Dict.insert identity name (A.At region tipe) rigidHeaders)
                                                            )
                                                            flexInfo
                                                    )
                                        )
                            )
