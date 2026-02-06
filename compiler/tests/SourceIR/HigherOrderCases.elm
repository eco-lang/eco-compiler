module SourceIR.HigherOrderCases exposing (expectSuite, testCases)

{-| Tests for higher-order function expressions.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , accessorExpr
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
        , makeModuleWithTypedDefsUnionsAliases
        , pAlias
        , pAnything
        , pCons
        , pCtor
        , pList
        , pRecord
        , pTuple
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Higher-order function tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    functionAsArgumentCases expectFn
        ++ functionReturningFunctionCases expectFn
        ++ compositionCases expectFn
        ++ partialApplicationCases expectFn
        ++ polymorphicHigherOrderCases expectFn
        ++ higherOrderWithPatternsCases expectFn
        ++ caseReturningFunctionCases expectFn



-- ============================================================================
-- FUNCTION AS ARGUMENT (6 tests)
-- ============================================================================


functionAsArgumentCases : (Src.Module -> Expectation) -> List TestCase
functionAsArgumentCases expectFn =
    [ { label = "Pass lambda to function", run = passLambdaToFunction expectFn }
    , { label = "Pass named function to higher-order", run = passNamedFunctionToHigherOrder expectFn }
    , { label = "Map-like function", run = mapLikeFunction expectFn }
    , { label = "Filter-like function", run = filterLikeFunction expectFn }

    -- Moved to TypeCheckFails.elm: , { label = "Fold-like function", run = foldLikeFunction expectFn }
    , { label = "Pass accessor function", run = passAccessorFunction expectFn }
    ]


passLambdaToFunction : (Src.Module -> Expectation) -> (() -> Expectation)
passLambdaToFunction expectFn _ =
    let
        applyFn =
            define "apply" [ pVar "f", pVar "x" ] (callExpr (varExpr "f") [ varExpr "x" ])

        fn =
            lambdaExpr [ pVar "n" ] (varExpr "n")

        modul =
            makeModule "testValue"
                (letExpr [ applyFn ]
                    (callExpr (varExpr "apply") [ fn, intExpr 42 ])
                )
    in
    expectFn modul


passNamedFunctionToHigherOrder : (Src.Module -> Expectation) -> (() -> Expectation)
passNamedFunctionToHigherOrder expectFn _ =
    let
        identity =
            define "identity" [ pVar "x" ] (varExpr "x")

        applyFn =
            define "apply" [ pVar "f", pVar "x" ] (callExpr (varExpr "f") [ varExpr "x" ])

        modul =
            makeModule "testValue"
                (letExpr [ identity, applyFn ]
                    (callExpr (varExpr "apply") [ varExpr "identity", intExpr 42 ])
                )
    in
    expectFn modul


mapLikeFunction : (Src.Module -> Expectation) -> (() -> Expectation)
mapLikeFunction expectFn _ =
    let
        mapFn =
            define "myMap"
                [ pVar "f", pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "h") (pVar "t")
                      , listExpr
                            [ callExpr (varExpr "f") [ varExpr "h" ]
                            ]
                      )
                    ]
                )

        double =
            lambdaExpr [ pVar "x" ] (tupleExpr (varExpr "x") (varExpr "x"))

        modul =
            makeModule "testValue"
                (letExpr [ mapFn ]
                    (callExpr (varExpr "myMap") [ double, listExpr [ intExpr 1, intExpr 2 ] ])
                )
    in
    expectFn modul


filterLikeFunction : (Src.Module -> Expectation) -> (() -> Expectation)
filterLikeFunction expectFn _ =
    let
        filterFn =
            define "myFilter"
                [ pVar "pred", pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "h") (pVar "t")
                      , ifExpr
                            (callExpr (varExpr "pred") [ varExpr "h" ])
                            (listExpr [ varExpr "h" ])
                            (listExpr [])
                      )
                    ]
                )

        alwaysTrue =
            lambdaExpr [ pAnything ] (boolExpr True)

        modul =
            makeModule "testValue"
                (letExpr [ filterFn ]
                    (callExpr (varExpr "myFilter") [ alwaysTrue, listExpr [ intExpr 1 ] ])
                )
    in
    expectFn modul


passAccessorFunction : (Src.Module -> Expectation) -> (() -> Expectation)
passAccessorFunction expectFn _ =
    let
        applyFn =
            define "apply" [ pVar "f", pVar "x" ] (callExpr (varExpr "f") [ varExpr "x" ])

        record =
            recordExpr [ ( "name", strExpr "test" ) ]

        modul =
            makeModule "testValue"
                (letExpr [ applyFn ]
                    (callExpr (varExpr "apply") [ accessorExpr "name", record ])
                )
    in
    expectFn modul



-- ============================================================================
-- FUNCTION RETURNING FUNCTION (6 tests)
-- ============================================================================


functionReturningFunctionCases : (Src.Module -> Expectation) -> List TestCase
functionReturningFunctionCases expectFn =
    [ { label = "Function returning lambda", run = functionReturningLambda expectFn }
    , { label = "Curried function", run = curriedFunction expectFn }
    , { label = "Triple nested function", run = tripleNestedFunction expectFn }
    , { label = "Function factory", run = functionFactory expectFn }
    , { label = "Return lambda based on condition", run = returnLambdaBasedOnCondition expectFn }
    , { label = "Closure over multiple variables", run = closureOverMultipleVariables expectFn }
    ]


functionReturningLambda : (Src.Module -> Expectation) -> (() -> Expectation)
functionReturningLambda expectFn _ =
    let
        makeFn =
            define "makeAdder"
                [ pVar "n" ]
                (lambdaExpr [ pVar "x" ] (tupleExpr (varExpr "n") (varExpr "x")))

        modul =
            makeModule "testValue"
                (letExpr [ makeFn ]
                    (callExpr (callExpr (varExpr "makeAdder") [ intExpr 5 ]) [ intExpr 3 ])
                )
    in
    expectFn modul


curriedFunction : (Src.Module -> Expectation) -> (() -> Expectation)
curriedFunction expectFn _ =
    let
        addFn =
            define "add"
                [ pVar "a" ]
                (lambdaExpr [ pVar "b" ] (tupleExpr (varExpr "a") (varExpr "b")))

        modul =
            makeModule "testValue"
                (letExpr [ addFn ]
                    (callExpr (varExpr "add") [ intExpr 1, intExpr 2 ])
                )
    in
    expectFn modul


tripleNestedFunction : (Src.Module -> Expectation) -> (() -> Expectation)
tripleNestedFunction expectFn _ =
    let
        fn =
            define "triple"
                [ pVar "a" ]
                (lambdaExpr [ pVar "b" ]
                    (lambdaExpr [ pVar "c" ]
                        (listExpr [ varExpr "a", varExpr "b", varExpr "c" ])
                    )
                )

        modul =
            makeModule "testValue"
                (letExpr [ fn ]
                    (callExpr (varExpr "triple") [ intExpr 1, intExpr 2, intExpr 3 ])
                )
    in
    expectFn modul


functionFactory : (Src.Module -> Expectation) -> (() -> Expectation)
functionFactory expectFn _ =
    let
        makeTransform =
            define "makeTransform"
                [ pVar "factor" ]
                (lambdaExpr [ pVar "x" ] (tupleExpr (varExpr "x") (varExpr "factor")))

        double =
            define "double" [] (callExpr (varExpr "makeTransform") [ intExpr 2 ])

        modul =
            makeModule "testValue"
                (letExpr [ makeTransform, double ]
                    (callExpr (varExpr "double") [ intExpr 5 ])
                )
    in
    expectFn modul


returnLambdaBasedOnCondition : (Src.Module -> Expectation) -> (() -> Expectation)
returnLambdaBasedOnCondition expectFn _ =
    let
        chooseFn =
            define "choose"
                [ pVar "flag" ]
                (ifExpr (varExpr "flag")
                    (lambdaExpr [ pVar "x" ] (varExpr "x"))
                    (lambdaExpr [ pAnything ] (intExpr 0))
                )

        modul =
            makeModule "testValue"
                (letExpr [ chooseFn ]
                    (callExpr (callExpr (varExpr "choose") [ boolExpr True ]) [ intExpr 42 ])
                )
    in
    expectFn modul


closureOverMultipleVariables : (Src.Module -> Expectation) -> (() -> Expectation)
closureOverMultipleVariables expectFn _ =
    let
        makeClosure =
            define "makeClosure"
                [ pVar "a", pVar "b", pVar "c" ]
                (lambdaExpr [ pVar "x" ]
                    (listExpr [ varExpr "a", varExpr "b", varExpr "c", varExpr "x" ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ makeClosure ]
                    (callExpr (varExpr "makeClosure") [ intExpr 1, intExpr 2, intExpr 3, intExpr 4 ])
                )
    in
    expectFn modul



-- ============================================================================
-- COMPOSITION (6 tests)
-- ============================================================================


compositionCases : (Src.Module -> Expectation) -> List TestCase
compositionCases expectFn =
    [ { label = "Compose two functions", run = composeTwoFunctions expectFn }
    , { label = "Flip function", run = flipFunction expectFn }
    , { label = "Const function", run = constFunction expectFn }
    , { label = "Identity composition", run = identityComposition expectFn }
    , { label = "Pipe-like apply", run = pipeLikeApply expectFn }
    ]


manualCompose : (Src.Module -> Expectation) -> (() -> Expectation)
manualCompose expectFn _ =
    let
        compose =
            define "compose"
                [ pVar "f", pVar "g" ]
                (lambdaExpr [ pVar "x" ]
                    (callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ compose ]
                    (varExpr "compose")
                )
    in
    expectFn modul


composeTwoFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
composeTwoFunctions expectFn _ =
    let
        compose =
            define "compose"
                [ pVar "f", pVar "g" ]
                (lambdaExpr [ pVar "x" ]
                    (callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ])
                )

        fn1 =
            lambdaExpr [ pVar "n" ] (tupleExpr (varExpr "n") (intExpr 0))

        fn2 =
            lambdaExpr [ pVar "n" ] (varExpr "n")

        composed =
            callExpr (varExpr "compose") [ fn1, fn2 ]

        modul =
            makeModule "testValue"
                (letExpr [ compose ]
                    (callExpr composed [ intExpr 42 ])
                )
    in
    expectFn modul


flipFunction : (Src.Module -> Expectation) -> (() -> Expectation)
flipFunction expectFn _ =
    let
        flipFn =
            define "flip"
                [ pVar "f" ]
                (lambdaExpr [ pVar "a", pVar "b" ]
                    (callExpr (varExpr "f") [ varExpr "b", varExpr "a" ])
                )

        pairFn =
            lambdaExpr [ pVar "x", pVar "y" ] (tupleExpr (varExpr "x") (varExpr "y"))

        modul =
            makeModule "testValue"
                (letExpr [ flipFn ]
                    (callExpr (callExpr (varExpr "flip") [ pairFn ]) [ intExpr 1, intExpr 2 ])
                )
    in
    expectFn modul


constFunction : (Src.Module -> Expectation) -> (() -> Expectation)
constFunction expectFn _ =
    let
        constFn =
            define "const"
                [ pVar "a" ]
                (lambdaExpr [ pAnything ] (varExpr "a"))

        modul =
            makeModule "testValue"
                (letExpr [ constFn ]
                    (callExpr (callExpr (varExpr "const") [ intExpr 42 ]) [ strExpr "ignored" ])
                )
    in
    expectFn modul


identityComposition : (Src.Module -> Expectation) -> (() -> Expectation)
identityComposition expectFn _ =
    let
        identity =
            define "identity" [ pVar "x" ] (varExpr "x")

        compose =
            define "compose"
                [ pVar "f", pVar "g" ]
                (lambdaExpr [ pVar "x" ]
                    (callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ identity, compose ]
                    (callExpr (callExpr (varExpr "compose") [ varExpr "identity", varExpr "identity" ]) [ intExpr 1 ])
                )
    in
    expectFn modul


pipeLikeApply : (Src.Module -> Expectation) -> (() -> Expectation)
pipeLikeApply expectFn _ =
    let
        pipe =
            define "pipe"
                [ pVar "x", pVar "f" ]
                (callExpr (varExpr "f") [ varExpr "x" ])

        fn =
            lambdaExpr [ pVar "n" ] (tupleExpr (varExpr "n") (varExpr "n"))

        modul =
            makeModule "testValue"
                (letExpr [ pipe ]
                    (callExpr (varExpr "pipe") [ intExpr 5, fn ])
                )
    in
    expectFn modul



-- ============================================================================
-- PARTIAL APPLICATION (4 tests)
-- ============================================================================


partialApplicationCases : (Src.Module -> Expectation) -> List TestCase
partialApplicationCases expectFn =
    [ { label = "Partially applied function stored", run = partiallyAppliedFunctionStored expectFn }
    , { label = "Multiple partial applications", run = multiplePartialApplications expectFn }
    , { label = "Partial application in list", run = partialApplicationInList expectFn }
    , { label = "Partial application in record", run = partialApplicationInRecord expectFn }
    ]


partiallyAppliedFunctionStored : (Src.Module -> Expectation) -> (() -> Expectation)
partiallyAppliedFunctionStored expectFn _ =
    let
        addFn =
            define "add" [ pVar "a", pVar "b" ] (tupleExpr (varExpr "a") (varExpr "b"))

        add5 =
            define "add5" [] (callExpr (varExpr "add") [ intExpr 5 ])

        modul =
            makeModule "testValue"
                (letExpr [ addFn, add5 ]
                    (callExpr (varExpr "add5") [ intExpr 3 ])
                )
    in
    expectFn modul


multiplePartialApplications : (Src.Module -> Expectation) -> (() -> Expectation)
multiplePartialApplications expectFn _ =
    let
        fn =
            define "fn"
                [ pVar "a", pVar "b", pVar "c" ]
                (listExpr [ varExpr "a", varExpr "b", varExpr "c" ])

        p1 =
            define "p1" [] (callExpr (varExpr "fn") [ intExpr 1 ])

        p2 =
            define "p2" [] (callExpr (varExpr "p1") [ intExpr 2 ])

        modul =
            makeModule "testValue"
                (letExpr [ fn, p1, p2 ]
                    (callExpr (varExpr "p2") [ intExpr 3 ])
                )
    in
    expectFn modul


partialApplicationInList : (Src.Module -> Expectation) -> (() -> Expectation)
partialApplicationInList expectFn _ =
    let
        addFn =
            define "add" [ pVar "a", pVar "b" ] (tupleExpr (varExpr "a") (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ addFn ]
                    (listExpr
                        [ callExpr (varExpr "add") [ intExpr 1 ]
                        , callExpr (varExpr "add") [ intExpr 2 ]
                        , callExpr (varExpr "add") [ intExpr 3 ]
                        ]
                    )
                )
    in
    expectFn modul


partialApplicationInRecord : (Src.Module -> Expectation) -> (() -> Expectation)
partialApplicationInRecord expectFn _ =
    let
        multFn =
            define "mult" [ pVar "a", pVar "b" ] (tupleExpr (varExpr "a") (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ multFn ]
                    (recordExpr
                        [ ( "double", callExpr (varExpr "mult") [ intExpr 2 ] )
                        , ( "triple", callExpr (varExpr "mult") [ intExpr 3 ] )
                        ]
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC HIGHER-ORDER (3 tests)
-- ============================================================================


polymorphicHigherOrderCases : (Src.Module -> Expectation) -> List TestCase
polymorphicHigherOrderCases expectFn =
    [ { label = "Identity used with different types", run = identityUsedWithDifferentTypes expectFn }
    , { label = "Apply used with different function types", run = applyUsedWithDifferentFunctionTypes expectFn }
    , { label = "Higher-order function preserving polymorphism", run = higherOrderPreservingPolymorphism expectFn }
    ]


identityUsedWithDifferentTypes : (Src.Module -> Expectation) -> (() -> Expectation)
identityUsedWithDifferentTypes expectFn _ =
    let
        -- let id x = x in (id 1, id "hello")
        idFn =
            define "id" [ pVar "x" ] (varExpr "x")

        body =
            tupleExpr
                (callExpr (varExpr "id") [ intExpr 1 ])
                (callExpr (varExpr "id") [ strExpr "hello" ])

        modul =
            makeModule "testValue"
                (letExpr [ idFn ] body)
    in
    expectFn modul


applyUsedWithDifferentFunctionTypes : (Src.Module -> Expectation) -> (() -> Expectation)
applyUsedWithDifferentFunctionTypes expectFn _ =
    let
        -- let apply f x = f x in
        -- let intId n = n in
        -- let strId s = s in
        -- (apply intId 1, apply strId "hi")
        applyFn =
            define "apply"
                [ pVar "f", pVar "x" ]
                (callExpr (varExpr "f") [ varExpr "x" ])

        intIdFn =
            define "intId" [ pVar "n" ] (varExpr "n")

        strIdFn =
            define "strId" [ pVar "s" ] (varExpr "s")

        body =
            tupleExpr
                (callExpr (varExpr "apply") [ varExpr "intId", intExpr 1 ])
                (callExpr (varExpr "apply") [ varExpr "strId", strExpr "hi" ])

        modul =
            makeModule "testValue"
                (letExpr [ applyFn, intIdFn, strIdFn ] body)
    in
    expectFn modul


higherOrderPreservingPolymorphism : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderPreservingPolymorphism expectFn _ =
    let
        -- let twice f x = f (f x) in
        -- let id x = x in
        -- (twice id 1, twice id "hi")
        twiceFn =
            define "twice"
                [ pVar "f", pVar "x" ]
                (callExpr (varExpr "f")
                    [ callExpr (varExpr "f") [ varExpr "x" ] ]
                )

        idFn =
            define "id" [ pVar "y" ] (varExpr "y")

        body =
            tupleExpr
                (callExpr (varExpr "twice") [ varExpr "id", intExpr 1 ])
                (callExpr (varExpr "twice") [ varExpr "id", strExpr "hi" ])

        modul =
            makeModule "testValue"
                (letExpr [ twiceFn, idFn ] body)
    in
    expectFn modul



-- ============================================================================
-- HIGHER-ORDER WITH PATTERNS (4 tests)
-- ============================================================================


higherOrderWithPatternsCases : (Src.Module -> Expectation) -> List TestCase
higherOrderWithPatternsCases expectFn =
    [ { label = "Higher-order with tuple pattern", run = higherOrderWithTuplePattern expectFn }
    , { label = "Higher-order with record pattern", run = higherOrderWithRecordPattern expectFn }
    , { label = "Higher-order with list pattern", run = higherOrderWithListPattern expectFn }
    , { label = "Higher-order with alias pattern", run = higherOrderWithAliasPattern expectFn }
    ]


higherOrderWithTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderWithTuplePattern expectFn _ =
    let
        applyToPair =
            define "applyToPair"
                [ pVar "f", pTuple (pVar "a") (pVar "b") ]
                (callExpr (varExpr "f") [ varExpr "a", varExpr "b" ])

        addFn =
            lambdaExpr [ pVar "x", pVar "y" ] (tupleExpr (varExpr "x") (varExpr "y"))

        modul =
            makeModule "testValue"
                (letExpr [ applyToPair ]
                    (callExpr (varExpr "applyToPair") [ addFn, tupleExpr (intExpr 1) (intExpr 2) ])
                )
    in
    expectFn modul


higherOrderWithRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderWithRecordPattern expectFn _ =
    let
        transformRecord =
            define "transformRecord"
                [ pVar "f", pRecord [ "value" ] ]
                (recordExpr [ ( "value", callExpr (varExpr "f") [ varExpr "value" ] ) ])

        doubleFn =
            lambdaExpr [ pVar "x" ] (tupleExpr (varExpr "x") (varExpr "x"))

        modul =
            makeModule "testValue"
                (letExpr [ transformRecord ]
                    (callExpr (varExpr "transformRecord") [ doubleFn, recordExpr [ ( "value", intExpr 21 ) ] ])
                )
    in
    expectFn modul


higherOrderWithListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderWithListPattern expectFn _ =
    let
        mapHead =
            define "mapHead"
                [ pVar "f", pCons (pVar "h") (pVar "t") ]
                (listExpr [ callExpr (varExpr "f") [ varExpr "h" ] ])

        fn =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ mapHead ]
                    (callExpr (varExpr "mapHead") [ fn, listExpr [ intExpr 1, intExpr 2 ] ])
                )
    in
    expectFn modul


higherOrderWithAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderWithAliasPattern expectFn _ =
    let
        withOriginal =
            define "withOriginal"
                [ pVar "f", pAlias (pVar "x") "original" ]
                (tupleExpr (callExpr (varExpr "f") [ varExpr "x" ]) (varExpr "original"))

        fn =
            lambdaExpr [ pVar "n" ] (varExpr "n")

        modul =
            makeModule "testValue"
                (letExpr [ withOriginal ]
                    (callExpr (varExpr "withOriginal") [ fn, intExpr 42 ])
                )
    in
    expectFn modul



-- ============================================================================
-- CASE RETURNING FUNCTION (GOPT_016) (2 tests)
-- ============================================================================


caseReturningFunctionCases : (Src.Module -> Expectation) -> List TestCase
caseReturningFunctionCases expectFn =
    [ { label = "Case returns curried binary operator", run = caseReturnsCurriedBinaryOp expectFn }
    , { label = "Case returns curried ternary function", run = caseReturnsCurriedTernaryFn expectFn }
    , { label = "Case returns differently staged lambdas", run = caseReturnsDifferentlyStagedLambdas expectFn }
    ]


{-| Tests MONO\_016: Wrapper closures must generate curried calls.

This test creates a function that returns a curried function based on
case matching on a custom type. When a higher-order function receives
this function as an argument, the wrapper closure must generate nested
MonoCall expressions respecting the curried structure.

    type Op = Add | Sub | Mul

    getOp : Op -> Int -> Int -> Int
    getOp op =
        case op of
            Add -> \a b -> a + b
            Sub -> \a b -> a - b
            Mul -> \a b -> a \* b

    -- This forces wrapper closure creation for getOp
    applyOp : (Op -> Int -> Int -> Int) -> Op -> Int -> Int -> Int
    applyOp f op a b = f op a b

    testValue = applyOp getOp Add 3 4

-}
caseReturnsCurriedBinaryOp : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturnsCurriedBinaryOp expectFn _ =
    let
        -- Define the Op union type
        opUnion : UnionDef
        opUnion =
            { name = "Op"
            , args = []
            , ctors =
                [ { name = "Add", args = [] }
                , { name = "Sub", args = [] }
                , { name = "Mul", args = [] }
                ]
            }

        -- Define getOp : Op -> Int -> Int -> Int
        getOpFn : TypedDef
        getOpFn =
            { name = "getOp"
            , args = [ pVar "op" ]
            , tipe = tLambda (tType "Op" []) (tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" [])))
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
                    , ( pCtor "Mul" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "*" ) ] (varExpr "b"))
                      )
                    ]
            }

        -- applyOp : (Op -> Int -> Int -> Int) -> Op -> Int -> Int -> Int
        -- applyOp f op a b = f op a b
        applyOpFn : TypedDef
        applyOpFn =
            { name = "applyOp"
            , args = [ pVar "f", pVar "op", pVar "a", pVar "b" ]
            , tipe =
                tLambda
                    (tLambda (tType "Op" []) (tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))))
                    (tLambda (tType "Op" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                callExpr (varExpr "f")
                    [ varExpr "op", varExpr "a", varExpr "b" ]
            }

        -- testValue = applyOp getOp Add 3 4
        testValueFn : TypedDef
        testValueFn =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "applyOp")
                    [ varExpr "getOp", ctorExpr "Add", intExpr 3, intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ getOpFn, applyOpFn, testValueFn ] [ opUnion ] []
    in
    expectFn modul


{-| Tests MONO\_016 with a ternary curried function passed to a higher-order function.

    type Mode
        = First
        | Second
        | Third

    choose : Mode -> Int -> Int -> Int -> Int
    choose mode =
        case mode of
            First ->
                \a b c -> a

            Second ->
                \a b c -> b

            Third ->
                \a b c -> c

    -- Forces wrapper closure creation for choose
    applyChoice : (Mode -> Int -> Int -> Int -> Int) -> Mode -> Int -> Int -> Int -> Int
    applyChoice f mode a b c =
        f mode a b c

    testValue =
        applyChoice choose First 10 20 30

-}
caseReturnsCurriedTernaryFn : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturnsCurriedTernaryFn expectFn _ =
    let
        -- Define the Mode union type
        modeUnion : UnionDef
        modeUnion =
            { name = "Mode"
            , args = []
            , ctors =
                [ { name = "First", args = [] }
                , { name = "Second", args = [] }
                , { name = "Third", args = [] }
                ]
            }

        -- Define choose : Mode -> Int -> Int -> Int -> Int
        chooseFn : TypedDef
        chooseFn =
            { name = "choose"
            , args = [ pVar "mode" ]
            , tipe =
                tLambda (tType "Mode" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "mode")
                    [ ( pCtor "First" []
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")
                      )
                    , ( pCtor "Second" []
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "b")
                      )
                    , ( pCtor "Third" []
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "c")
                      )
                    ]
            }

        -- applyChoice : (Mode -> Int -> Int -> Int -> Int) -> Mode -> Int -> Int -> Int -> Int
        -- applyChoice f mode a b c = f mode a b c
        applyChoiceFn : TypedDef
        applyChoiceFn =
            { name = "applyChoice"
            , args = [ pVar "f", pVar "mode", pVar "a", pVar "b", pVar "c" ]
            , tipe =
                tLambda
                    (tLambda (tType "Mode" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" [])
                                (tLambda (tType "Int" []) (tType "Int" []))
                            )
                        )
                    )
                    (tLambda (tType "Mode" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" [])
                                (tLambda (tType "Int" []) (tType "Int" []))
                            )
                        )
                    )
            , body =
                callExpr (varExpr "f")
                    [ varExpr "mode", varExpr "a", varExpr "b", varExpr "c" ]
            }

        -- testValue = applyChoice choose First 10 20 30
        testValueFn : TypedDef
        testValueFn =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "applyChoice")
                    [ varExpr "choose", ctorExpr "First", intExpr 10, intExpr 20, intExpr 30 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ chooseFn, applyChoiceFn, testValueFn ] [ modeUnion ] []
    in
    expectFn modul


{-| Tests MONO\_018: MonoCase branch result types must match MonoCase resultType.

This test creates different syntactic lambda nestings across branches that have
the same Elm type but potentially different staging boundaries in Mono IR:

    type Selector
        = UseFlat
        | UseNested

    selectFn : Selector -> Int -> Int -> Int -> Int
    selectFn sel a =
        case sel of
            UseFlat ->
                \b c -> a + b + c

            -- single 2-arg lambda
            UseNested ->
                \b -> \c -> a + b + c

    -- nested single-arg lambdas
    testValue =
        selectFn UseFlat 1 2 3

If monomorphization doesn't normalize these to the same MFunction shape, the
branches would have different MonoTypes, violating MONO\_018.

-}
caseReturnsDifferentlyStagedLambdas : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturnsDifferentlyStagedLambdas expectFn _ =
    let
        -- Define the Selector union type
        selectorUnion : UnionDef
        selectorUnion =
            { name = "Selector"
            , args = []
            , ctors =
                [ { name = "UseFlat", args = [] }
                , { name = "UseNested", args = [] }
                ]
            }

        -- selectFn : Selector -> Int -> Int -> Int -> Int
        -- selectFn sel a =
        --     case sel of
        --         UseFlat -> \b c -> a + b + c
        --         UseNested -> \b -> \c -> a + b + c
        selectFn : TypedDef
        selectFn =
            { name = "selectFn"
            , args = [ pVar "sel", pVar "a" ]
            , tipe =
                tLambda (tType "Selector" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "sel")
                    [ ( pCtor "UseFlat" []
                      , lambdaExpr [ pVar "b", pVar "c" ]
                            (binopsExpr
                                [ ( binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"), "+" ) ]
                                (varExpr "c")
                            )
                      )
                    , ( pCtor "UseNested" []
                      , lambdaExpr [ pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr
                                    [ ( binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"), "+" ) ]
                                    (varExpr "c")
                                )
                            )
                      )
                    ]
            }

        -- testValue = selectFn UseFlat 1 2 3
        testValueFn : TypedDef
        testValueFn =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "selectFn")
                    [ ctorExpr "UseFlat", intExpr 1, intExpr 2, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ selectFn, testValueFn ] [ selectorUnion ] []
    in
    expectFn modul
