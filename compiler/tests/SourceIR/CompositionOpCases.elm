module SourceIR.CompositionOpCases exposing (expectSuite)

{-| Tests for composition operators, triple case, Order case, and case returning functions.

Covers gaps 18, 22, 23, 24 from e2e-to-elmtest.md:
  - Function composition operators (>> and <<)
  - Case on triple (3-tuple) with literal patterns
  - Case on Order type (LT, EQ, GT)
  - Case returning functions (staged case with partial application)

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pInt
        , pTuple3
        , pVar
        , qualVarExpr
        , strExpr
        , tLambda
        , tType
        , tuple3Expr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Composition operators and staged case " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    compositionOpCases expectFn
        ++ tripleCaseCases expectFn
        ++ orderCaseCases expectFn
        ++ caseReturningFunctionCases expectFn



-- ============================================================================
-- FUNCTION COMPOSITION OPERATORS >> and << (Gap 18)
-- ============================================================================


compositionOpCases : (Src.Module -> Expectation) -> List TestCase
compositionOpCases expectFn =
    [ { label = "ComposeR (>>) two functions", run = composeRightTwoFunctions expectFn }
    , { label = "ComposeL (<<) two functions", run = composeLeftTwoFunctions expectFn }
    , { label = "ComposeR applied to value", run = composeRightApplied expectFn }
    , { label = "ComposeL applied to value", run = composeLeftApplied expectFn }
    , { label = "ComposeR chain of three functions", run = composeRightChain expectFn }
    ]


{-| addOneThenDouble = addOne >> double
Uses the >> operator via binopsExpr.
-}
composeRightTwoFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
composeRightTwoFunctions expectFn _ =
    let
        addOne =
            define "addOne" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        -- addOneThenDouble = addOne >> double
        composed =
            define "addOneThenDouble" [] (binopsExpr [ ( varExpr "addOne", ">>" ) ] (varExpr "double"))

        -- testValue = addOneThenDouble 9  =>  (9 + 1) * 2 = 20
        modul =
            makeModule "testValue"
                (letExpr [ addOne, double, composed ]
                    (callExpr (varExpr "addOneThenDouble") [ intExpr 9 ])
                )
    in
    expectFn modul


{-| doubleThenAddOne = addOne << double
Uses the << operator via binopsExpr.
-}
composeLeftTwoFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
composeLeftTwoFunctions expectFn _ =
    let
        addOne =
            define "addOne" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        -- doubleThenAddOne = addOne << double  means addOne(double(x))
        composed =
            define "doubleThenAddOne" [] (binopsExpr [ ( varExpr "addOne", "<<" ) ] (varExpr "double"))

        -- testValue = doubleThenAddOne 5  =>  (5 * 2) + 1 = 11
        modul =
            makeModule "testValue"
                (letExpr [ addOne, double, composed ]
                    (callExpr (varExpr "doubleThenAddOne") [ intExpr 5 ])
                )
    in
    expectFn modul


{-| compose then immediately apply: (addOne >> double) 9
-}
composeRightApplied : (Src.Module -> Expectation) -> (() -> Expectation)
composeRightApplied expectFn _ =
    let
        addOne =
            define "addOne" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        modul =
            makeModule "testValue"
                (letExpr [ addOne, double ]
                    (callExpr (binopsExpr [ ( varExpr "addOne", ">>" ) ] (varExpr "double")) [ intExpr 9 ])
                )
    in
    expectFn modul


{-| compose then immediately apply with <<: (addOne << double) 5
-}
composeLeftApplied : (Src.Module -> Expectation) -> (() -> Expectation)
composeLeftApplied expectFn _ =
    let
        addOne =
            define "addOne" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        modul =
            makeModule "testValue"
                (letExpr [ addOne, double ]
                    (callExpr (binopsExpr [ ( varExpr "addOne", "<<" ) ] (varExpr "double")) [ intExpr 5 ])
                )
    in
    expectFn modul


{-| Chain of three: addOne >> double >> addOne applied to 4
Result: addOne(double(addOne(4))) = addOne(double(5)) = addOne(10) = 11
-}
composeRightChain : (Src.Module -> Expectation) -> (() -> Expectation)
composeRightChain expectFn _ =
    let
        addOne =
            define "addOne" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        -- addOne >> double >> addOne
        composed =
            define "chain" []
                (binopsExpr [ ( varExpr "addOne", ">>" ), ( varExpr "double", ">>" ) ] (varExpr "addOne"))

        modul =
            makeModule "testValue"
                (letExpr [ addOne, double, composed ]
                    (callExpr (varExpr "chain") [ intExpr 4 ])
                )
    in
    expectFn modul



-- ============================================================================
-- CASE ON TRIPLE (3-TUPLE) WITH LITERAL PATTERNS (Gap 22)
-- ============================================================================


tripleCaseCases : (Src.Module -> Expectation) -> List TestCase
tripleCaseCases expectFn =
    [ { label = "Case on triple with all-zero literal pattern", run = caseTripleAllZero expectFn }
    , { label = "Case on triple with mixed wildcard patterns", run = caseTripleMixedWildcards expectFn }
    , { label = "Case on triple with variable extraction", run = caseTripleVarExtraction expectFn }
    ]


{-| case (0, 0, 0) of
    (0, 0, 0) -> "all zero"
    _ -> "other"
-}
caseTripleAllZero : (Src.Module -> Expectation) -> (() -> Expectation)
caseTripleAllZero expectFn _ =
    let
        subject =
            tuple3Expr (intExpr 0) (intExpr 0) (intExpr 0)

        modul =
            makeModule "testValue"
                (caseExpr subject
                    [ ( pTuple3 (pInt 0) (pInt 0) (pInt 0), strExpr "all zero" )
                    , ( pAnything, strExpr "other" )
                    ]
                )
    in
    expectFn modul


{-| case (0, 1, 0) of
    (0, 0, 0) -> "all zero"
    (0, _, _) -> "x zero"
    (_, _, 0) -> "z zero"
    _ -> "none zero"
-}
caseTripleMixedWildcards : (Src.Module -> Expectation) -> (() -> Expectation)
caseTripleMixedWildcards expectFn _ =
    let
        subject =
            tuple3Expr (intExpr 0) (intExpr 1) (intExpr 0)

        modul =
            makeModule "testValue"
                (caseExpr subject
                    [ ( pTuple3 (pInt 0) (pInt 0) (pInt 0), strExpr "all zero" )
                    , ( pTuple3 (pInt 0) pAnything pAnything, strExpr "x zero" )
                    , ( pTuple3 pAnything pAnything (pInt 0), strExpr "z zero" )
                    , ( pAnything, strExpr "none zero" )
                    ]
                )
    in
    expectFn modul


{-| case (1, 2, 3) of
    (a, b, c) -> a + b + c
-}
caseTripleVarExtraction : (Src.Module -> Expectation) -> (() -> Expectation)
caseTripleVarExtraction expectFn _ =
    let
        subject =
            tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3)

        modul =
            makeModule "testValue"
                (caseExpr subject
                    [ ( pTuple3 (pVar "a") (pVar "b") (pVar "c")
                      , binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
                      )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- CASE ON ORDER TYPE (LT, EQ, GT) (Gap 23)
-- ============================================================================


orderCaseCases : (Src.Module -> Expectation) -> List TestCase
orderCaseCases expectFn =
    [ { label = "Case on Order with LT/EQ/GT patterns", run = caseOrderPatterns expectFn }
    , { label = "Case on compare result", run = caseCompareResult expectFn }
    ]


{-| orderToStr ord = case ord of LT -> "less"; EQ -> "equal"; GT -> "greater"
testValue = orderToStr LT
-}
caseOrderPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
caseOrderPatterns expectFn _ =
    let
        orderToStr =
            define "orderToStr"
                [ pVar "ord" ]
                (caseExpr (varExpr "ord")
                    [ ( pCtor "LT" [], strExpr "less" )
                    , ( pCtor "EQ" [], strExpr "equal" )
                    , ( pCtor "GT" [], strExpr "greater" )
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ orderToStr ]
                    (callExpr (varExpr "orderToStr") [ ctorExpr "LT" ])
                )
    in
    expectFn modul


{-| testValue = case compare 1 2 of LT -> "less"; EQ -> "equal"; GT -> "greater"
Uses qualVarExpr "Basics" "compare" to reference the compare function.
-}
caseCompareResult : (Src.Module -> Expectation) -> (() -> Expectation)
caseCompareResult expectFn _ =
    let
        compareCall =
            callExpr (qualVarExpr "Basics" "compare") [ intExpr 1, intExpr 2 ]

        modul =
            makeModule "testValue"
                (caseExpr compareCall
                    [ ( pCtor "LT" [], strExpr "less" )
                    , ( pCtor "EQ" [], strExpr "equal" )
                    , ( pCtor "GT" [], strExpr "greater" )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- CASE RETURNING FUNCTIONS / STAGED CASE (Gap 24)
-- ============================================================================


caseReturningFunctionCases : (Src.Module -> Expectation) -> List TestCase
caseReturningFunctionCases expectFn =
    [ { label = "Case returns lambda, then apply", run = caseReturnsLambdaThenApply expectFn }
    , { label = "Case returns lambda, partial application", run = caseReturnsLambdaPartialApp expectFn }
    ]


{-| type Op = Add | Sub
getOp op = case op of Add -> \a b -> a + b; Sub -> \a b -> a - b
testValue = (getOp Add) 3 4  =>  7
-}
caseReturnsLambdaThenApply : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturnsLambdaThenApply expectFn _ =
    let
        opUnion : UnionDef
        opUnion =
            { name = "Op"
            , args = []
            , ctors =
                [ { name = "Add", args = [] }
                , { name = "Sub", args = [] }
                ]
            }

        intType =
            tType "Int" []

        getOpDef : TypedDef
        getOpDef =
            { name = "getOp"
            , args = [ pVar "op" ]
            , tipe = tLambda (tType "Op" []) (tLambda intType (tLambda intType intType))
            , body =
                caseExpr (varExpr "op")
                    [ ( pCtor "Add" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                      )
                    , ( pCtor "Sub" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b"))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = intType
            , body =
                callExpr
                    (callExpr (varExpr "getOp") [ ctorExpr "Add" ])
                    [ intExpr 3, intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ getOpDef, testValueDef ] [ opUnion ] []
    in
    expectFn modul


{-| Partial application of case-returned function:
getOp Add returns \a b -> a + b
addFive = getOp Add 5  (partial application)
testValue = addFive 10  =>  15
-}
caseReturnsLambdaPartialApp : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturnsLambdaPartialApp expectFn _ =
    let
        opUnion : UnionDef
        opUnion =
            { name = "Op"
            , args = []
            , ctors =
                [ { name = "Add", args = [] }
                , { name = "Sub", args = [] }
                ]
            }

        intType =
            tType "Int" []

        getOpDef : TypedDef
        getOpDef =
            { name = "getOp"
            , args = [ pVar "op" ]
            , tipe = tLambda (tType "Op" []) (tLambda intType (tLambda intType intType))
            , body =
                caseExpr (varExpr "op")
                    [ ( pCtor "Add" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                      )
                    , ( pCtor "Sub" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b"))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = intType
            , body =
                letExpr
                    [ define "addFive" [] (callExpr (varExpr "getOp") [ ctorExpr "Add", intExpr 5 ]) ]
                    (callExpr (varExpr "addFive") [ intExpr 10 ])
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ getOpDef, testValueDef ] [ opUnion ] []
    in
    expectFn modul
