module Compiler.Generate.CodeGen.CaseScrutineeTypeTest exposing (suite)

{-| Tests for CGEN_037: Case Scrutinee Type Agreement invariant.

`eco.case` scrutinee is `i1` only for boolean cases; otherwise `!eco.value`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( UnionDef
        , boolExpr
        , caseExpr
        , ctorExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pCons
        , pCtor
        , pList
        , pVar
        , tType
        , tVar
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findOpsNamed
        , getStringAttr
        , isEcoValueType
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_037: Case Scrutinee Type Agreement"
        [ Test.test "Boolean case has i1 scrutinee" booleanCaseI1Test
        , Test.test "ADT case (Maybe) has !eco.value scrutinee" adtCaseEcoValueTest
        , Test.test "List case has !eco.value scrutinee" listCaseEcoValueTest
        , Test.test "case_kind ctor requires !eco.value" caseKindCtorTest
        ]



-- INVARIANT CHECKER


{-| Check case scrutinee type invariants.
-}
checkCaseScrutineeType : MlirModule -> List Violation
checkCaseScrutineeType mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule

        violations =
            List.filterMap checkCaseScrutinee caseOps
    in
    violations


checkCaseScrutinee : MlirOp -> Maybe Violation
checkCaseScrutinee op =
    let
        maybeOperandTypes =
            extractOperandTypes op

        maybeCaseKind =
            getStringAttr "case_kind" op
    in
    case maybeOperandTypes of
        Nothing ->
            -- Can't verify
            Nothing

        Just [] ->
            -- No scrutinee
            Nothing

        Just (scrutineeType :: _) ->
            let
                isBooleanCase =
                    scrutineeType == I1

                -- If case_kind is specified, validate consistency
                caseKindRequiresEcoValue =
                    case maybeCaseKind of
                        Just kind ->
                            List.member kind [ "ctor", "int", "chr", "str" ]

                        Nothing ->
                            False
            in
            -- case_kind specified as ctor/int/chr/str requires !eco.value scrutinee
            if caseKindRequiresEcoValue && not (isEcoValueType scrutineeType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "case_kind="
                            ++ Maybe.withDefault "?" maybeCaseKind
                            ++ " requires !eco.value scrutinee, got "
                            ++ typeToString scrutineeType
                    }

            else if isBooleanCase && caseKindRequiresEcoValue then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "Boolean case (i1 scrutinee) but case_kind="
                            ++ Maybe.withDefault "?" maybeCaseKind
                            ++ " suggests non-boolean"
                    }

            else
                Nothing


typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            name

        FunctionType _ ->
            "function"



-- TEST HELPER


{-| Maybe union type for tests.
-}
maybeUnion : UnionDef
maybeUnion =
    { name = "Maybe"
    , args = [ "a" ]
    , ctors =
        [ { name = "Just", args = [ tVar "a" ] }
        , { name = "Nothing", args = [] }
        ]
    }


{-| Helper to create a module that includes the Maybe type.
-}
makeModuleWithMaybe : String -> Src.Expr -> Src.Module
makeModuleWithMaybe name expr =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = name
          , args = []
          , tipe = tType "Int" []
          , body = expr
          }
        ]
        [ maybeUnion ]
        []


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseScrutineeType mlirModule)



-- TEST CASES


booleanCaseI1Test : () -> Expectation
booleanCaseI1Test _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True) (intExpr 1) (intExpr 0))
    in
    runInvariantTest modul


adtCaseEcoValueTest : () -> Expectation
adtCaseEcoValueTest _ =
    let
        modul =
            makeModuleWithMaybe "testValue"
                (caseExpr (ctorExpr "Nothing")
                    [ ( pCtor "Just" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Nothing" [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


listCaseEcoValueTest : () -> Expectation
listCaseEcoValueTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (listExpr [ intExpr 1 ])
                    [ ( pCons (pVar "x") (pVar "rest"), varExpr "x" )
                    , ( pList [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


caseKindCtorTest : () -> Expectation
caseKindCtorTest _ =
    -- ADT case should use !eco.value
    let
        modul =
            makeModuleWithMaybe "testValue"
                (caseExpr (ctorExpr "Nothing")
                    [ ( pCtor "Nothing" [], intExpr 0 )
                    , ( pCtor "Just" [ pVar "v" ], varExpr "v" )
                    ]
                )
    in
    runInvariantTest modul
