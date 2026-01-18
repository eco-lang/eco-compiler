module Compiler.Generate.CodeGen.CaseKindScrutineeTest exposing (suite)

{-| Tests for CGEN_043: Case Kind Scrutinee Type Agreement invariant.

`eco.case` scrutinee representation and `case_kind` must agree:

  - `case_kind="bool"` requires `i1` scrutinee
  - `case_kind="int"` requires `i64` scrutinee
  - `case_kind="chr"` requires `i16` (ECO char) scrutinee
  - `case_kind="ctor"` requires `!eco.value` scrutinee
  - `case_kind="str"` requires `!eco.value` scrutinee

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
        , pInt
        , pList
        , pVar
        , strExpr
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
        , typesMatch
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_043: Case Kind Scrutinee Type Agreement"
        [ Test.test "case_kind=bool requires i1 scrutinee" caseKindBoolTest
        , Test.test "case_kind=int requires i64 scrutinee" caseKindIntTest
        , Test.test "case_kind=ctor requires !eco.value scrutinee" caseKindCtorTest
        , Test.test "List case should use ctor kind with !eco.value" listCaseCtorTest
        , Test.test "Nested bool/ctor cases have correct types" nestedCasesTest
        ]



-- INVARIANT CHECKER


{-| Check case kind scrutinee type invariants.
-}
checkCaseKindScrutinee : MlirModule -> List Violation
checkCaseKindScrutinee mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule

        violations =
            List.filterMap checkCaseOp caseOps
    in
    violations


checkCaseOp : MlirOp -> Maybe Violation
checkCaseOp op =
    let
        maybeCaseKind =
            getStringAttr "case_kind" op

        maybeOperandTypes =
            extractOperandTypes op
    in
    case ( maybeCaseKind, maybeOperandTypes ) of
        ( Nothing, _ ) ->
            -- No case_kind attribute - cannot validate
            Nothing

        ( _, Nothing ) ->
            -- No operand types - cannot validate
            Nothing

        ( _, Just [] ) ->
            -- No scrutinee - cannot validate
            Nothing

        ( Just caseKind, Just (scrutineeType :: _) ) ->
            validateCaseKind caseKind scrutineeType op


validateCaseKind : String -> MlirType -> MlirOp -> Maybe Violation
validateCaseKind caseKind scrutineeType op =
    let
        ( expectedType, expectedDesc ) =
            case caseKind of
                "bool" ->
                    ( Just I1, "i1" )

                "int" ->
                    ( Just I64, "i64" )

                "chr" ->
                    ( Just I16, "i16 (ECO char)" )

                "ctor" ->
                    ( Just (NamedStruct "!eco.value"), "!eco.value" )

                "str" ->
                    ( Just (NamedStruct "!eco.value"), "!eco.value" )

                _ ->
                    ( Nothing, "unknown" )
    in
    case expectedType of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "Unknown case_kind='" ++ caseKind ++ "'"
                }

        Just expected ->
            if typesMatch scrutineeType expected then
                Nothing

            else
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "case_kind='"
                            ++ caseKind
                            ++ "' requires "
                            ++ expectedDesc
                            ++ " scrutinee, got "
                            ++ typeToString scrutineeType
                    }


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
            violationsToExpectation (checkCaseKindScrutinee mlirModule)



-- TEST CASES


caseKindBoolTest : () -> Expectation
caseKindBoolTest _ =
    -- Boolean case (if-then-else) should have i1 scrutinee
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True) (intExpr 1) (intExpr 0))
    in
    runInvariantTest modul


caseKindIntTest : () -> Expectation
caseKindIntTest _ =
    -- Integer case should have i64 scrutinee
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 5)
                    [ ( pInt 1, intExpr 10 )
                    , ( pInt 2, intExpr 20 )
                    , ( pVar "_", intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


caseKindCtorTest : () -> Expectation
caseKindCtorTest _ =
    -- ADT case should have !eco.value scrutinee
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


listCaseCtorTest : () -> Expectation
listCaseCtorTest _ =
    -- List pattern matching should use ctor case with !eco.value
    let
        modul =
            makeModule "testValue"
                (caseExpr (listExpr [ intExpr 1, intExpr 2 ])
                    [ ( pCons (pVar "x") (pVar "rest"), varExpr "x" )
                    , ( pList [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


nestedCasesTest : () -> Expectation
nestedCasesTest _ =
    -- Nested cases with different kinds should all validate
    let
        modul =
            makeModuleWithMaybe "testValue"
                (caseExpr (ctorExpr "Nothing")
                    [ ( pCtor "Just" [ pVar "x" ]
                      , ifExpr (boolExpr True) (varExpr "x") (intExpr 0)
                      )
                    , ( pCtor "Nothing" []
                      , intExpr 0
                      )
                    ]
                )
    in
    runInvariantTest modul
