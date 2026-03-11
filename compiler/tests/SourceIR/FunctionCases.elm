module SourceIR.FunctionCases exposing (expectSuite)

{-| Tests for function expressions: lambdas, calls, partial application.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , callExpr
        , chrExpr
        , ctorExpr
        , define
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModule
        , makeModuleWithDefs
        , makeModuleWithTypedDefs
        , makeModuleWithTypedDefsUnionsAliases
        , negateExpr
        , pAnything
        , pRecord
        , pTuple
        , pVar
        , qualVarExpr
        , recordExpr
        , strExpr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Function expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    lambdaCases expectFn
        ++ callCases expectFn
        ++ partialApplicationCases expectFn
        ++ nestedFunctionCases expectFn
        ++ functionWithPatternsCases expectFn
        ++ higherOrderCases expectFn
        ++ negateCases expectFn
        ++ absCases expectFn
        ++ polymorphicNumberCases expectFn



-- ============================================================================
-- LAMBDA EXPRESSIONS
-- ============================================================================


lambdaCases : (Src.Module -> Expectation) -> List TestCase
lambdaCases expectFn =
    [ { label = "Identity lambda", run = identityLambda expectFn }
    , { label = "Two-argument lambda", run = twoArgumentLambda expectFn }
    , { label = "Lambda returning tuple", run = lambdaReturningTuple expectFn }
    , { label = "Lambda with wildcard pattern", run = lambdaWithWildcard expectFn }
    ]


identityLambda : (Src.Module -> Expectation) -> (() -> Expectation)
identityLambda expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pVar "x" ] (varExpr "x") )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1 ] )
                ]
    in
    expectFn modul


twoArgumentLambda : (Src.Module -> Expectation) -> (() -> Expectation)
twoArgumentLambda expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x") )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1, strExpr "a" ] )
                ]
    in
    expectFn modul


lambdaReturningTuple : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaReturningTuple expectFn _ =
    let
        body =
            tupleExpr (varExpr "x") (varExpr "y")

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pVar "x", pVar "y" ] body )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1, strExpr "a" ] )
                ]
    in
    expectFn modul


lambdaWithWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithWildcard expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pAnything ] (intExpr 42) )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1 ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- FUNCTION CALLS
-- ============================================================================


callCases : (Src.Module -> Expectation) -> List TestCase
callCases expectFn =
    [ { label = "Call with one int arg", run = callWithOneIntArg expectFn }
    , { label = "Call with two args", run = callWithTwoArgs expectFn }
    , { label = "Nested calls", run = nestedCalls expectFn }
    ]


callWithOneIntArg : (Src.Module -> Expectation) -> (() -> Expectation)
callWithOneIntArg expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        def =
            define "f" [] fn

        modul =
            makeModule "testValue" (letExpr [ def ] (callExpr (varExpr "f") [ intExpr 42 ]))
    in
    expectFn modul


callWithTwoArgs : (Src.Module -> Expectation) -> (() -> Expectation)
callWithTwoArgs expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x")

        def =
            define "f" [] fn

        modul =
            makeModule "testValue" (letExpr [ def ] (callExpr (varExpr "f") [ intExpr 1, intExpr 2 ]))
    in
    expectFn modul


nestedCalls : (Src.Module -> Expectation) -> (() -> Expectation)
nestedCalls expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        def =
            define "f" [] fn

        innerCall =
            callExpr (varExpr "f") [ intExpr 1 ]

        outerCall =
            callExpr (varExpr "f") [ innerCall ]

        modul =
            makeModule "testValue" (letExpr [ def ] outerCall)
    in
    expectFn modul



-- ============================================================================
-- PARTIAL APPLICATION
-- ============================================================================


partialApplicationCases : (Src.Module -> Expectation) -> List TestCase
partialApplicationCases expectFn =
    [ { label = "Partially applied two-arg function", run = partiallyAppliedTwoArg expectFn }
    , { label = "Chained partial application", run = chainedPartialApplication expectFn }
    , { label = "Chained partial application (Float)", run = chainedPartialApplicationFloat expectFn }
    , { label = "Chained partial application (Char)", run = chainedPartialApplicationChar expectFn }
    , { label = "Chained partial application (Bool)", run = chainedPartialApplicationBool expectFn }
    , { label = "Chained partial application (String)", run = chainedPartialApplicationString expectFn }
    , { label = "Chained partial application (Record)", run = chainedPartialApplicationRecord expectFn }
    , { label = "Chained partial application (Custom)", run = chainedPartialApplicationCustom expectFn }
    ]


partiallyAppliedTwoArg : (Src.Module -> Expectation) -> (() -> Expectation)
partiallyAppliedTwoArg expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "x", pVar "y" ] (tupleExpr (varExpr "x") (varExpr "y"))

        def =
            define "f" [] fn

        partial =
            callExpr (varExpr "f") [ intExpr 1 ]

        modul =
            makeModule "testValue" (letExpr [ def ] partial)
    in
    expectFn modul


chainedPartialApplication : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplication expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ intExpr 1 ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


chainedPartialApplicationFloat : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationFloat expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ floatExpr 1.5 ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


chainedPartialApplicationChar : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationChar expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ chrExpr "x" ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


chainedPartialApplicationBool : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationBool expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ boolExpr True ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


chainedPartialApplicationString : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationString expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ strExpr "hello" ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


chainedPartialApplicationRecord : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationRecord expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ] ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


chainedPartialApplicationCustom : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationCustom expectFn _ =
    let
        wrapperUnion : UnionDef
        wrapperUnion =
            { name = "Wrapper"
            , args = []
            , ctors = [ { name = "Wrapper", args = [ tType "Int" [] ] } ]
            }

        fnDef : TypedDef
        fnDef =
            { name = "f"
            , args = [ pVar "a", pVar "b", pVar "c" ]
            , tipe = tLambda (tType "Wrapper" []) (tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Wrapper" [])))
            , body = varExpr "a"
            }

        p1Def : TypedDef
        p1Def =
            { name = "p1"
            , args = []
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Wrapper" []))
            , body = callExpr (varExpr "f") [ callExpr (ctorExpr "Wrapper") [ intExpr 42 ] ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tLambda (tType "Int" []) (tType "Wrapper" [])
            , body = callExpr (varExpr "p1") [ intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ fnDef, p1Def, testValueDef ] [ wrapperUnion ] []
    in
    expectFn modul



-- ============================================================================
-- NESTED FUNCTIONS
-- ============================================================================


nestedFunctionCases : (Src.Module -> Expectation) -> List TestCase
nestedFunctionCases expectFn =
    [ { label = "Lambda returning lambda", run = lambdaReturningLambda expectFn }
    , { label = "Lambda inside let inside lambda", run = lambdaInsideLetInsideLambda expectFn }
    , { label = "Multiple lambdas in tuple", run = multipleLambdasInTuple expectFn }
    ]


lambdaReturningLambda : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaReturningLambda expectFn _ =
    let
        inner =
            lambdaExpr [ pVar "y" ] (varExpr "y")

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pVar "x" ] inner )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1, strExpr "a" ] )
                ]
    in
    expectFn modul


lambdaInsideLetInsideLambda : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaInsideLetInsideLambda expectFn _ =
    let
        innerLambda =
            lambdaExpr [ pVar "y" ] (varExpr "y")

        def =
            define "inner" [] innerLambda

        body =
            letExpr [ def ] (callExpr (varExpr "inner") [ varExpr "x" ])

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pVar "x" ] body )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1 ] )
                ]
    in
    expectFn modul


multipleLambdasInTuple : (Src.Module -> Expectation) -> (() -> Expectation)
multipleLambdasInTuple expectFn _ =
    let
        lambda1 =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        lambda2 =
            lambdaExpr [ pVar "y" ] (intExpr 0)

        modul =
            makeModule "testValue" (tupleExpr lambda1 lambda2)
    in
    expectFn modul



-- ============================================================================
-- FUNCTIONS WITH PATTERNS
-- ============================================================================


functionWithPatternsCases : (Src.Module -> Expectation) -> List TestCase
functionWithPatternsCases expectFn =
    [ { label = "Lambda with tuple pattern", run = lambdaWithTuplePattern expectFn }
    , { label = "Lambda with record pattern", run = lambdaWithRecordPattern expectFn }
    , { label = "Lambda with mixed patterns", run = lambdaWithMixedPatterns expectFn }
    , { label = "Top-level function with patterns", run = topLevelFunctionWithPatterns expectFn }
    ]


lambdaWithTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithTuplePattern expectFn _ =
    let
        pattern =
            pTuple (pVar "x") (pVar "y")

        body =
            tupleExpr (varExpr "y") (varExpr "x")

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pattern ] body )
                , ( "testValue", [], callExpr (varExpr "testFn") [ tupleExpr (intExpr 1) (strExpr "a") ] )
                ]
    in
    expectFn modul


lambdaWithRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithRecordPattern expectFn _ =
    let
        pattern =
            pRecord [ "x" ]

        body =
            varExpr "x"

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pattern ] body )
                , ( "testValue", [], callExpr (varExpr "testFn") [ recordExpr [ ( "x", intExpr 1 ) ] ] )
                ]
    in
    expectFn modul


lambdaWithMixedPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithMixedPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn"
                  , []
                  , lambdaExpr
                        [ pVar "a"
                        , pTuple (pVar "b") (pVar "c")
                        , pAnything
                        ]
                        (varExpr "b")
                  )
                , ( "testValue"
                  , []
                  , callExpr (varExpr "testFn") [ intExpr 1, tupleExpr (strExpr "a") (intExpr 2), intExpr 3 ]
                  )
                ]
    in
    expectFn modul


topLevelFunctionWithPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
topLevelFunctionWithPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "swap", [ pTuple (pVar "a") (pVar "b") ], tupleExpr (varExpr "b") (varExpr "a") )
                , ( "testValue", [], callExpr (varExpr "swap") [ tupleExpr (intExpr 1) (strExpr "a") ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- HIGHER-ORDER FUNCTIONS
-- ============================================================================


higherOrderCases : (Src.Module -> Expectation) -> List TestCase
higherOrderCases expectFn =
    [ { label = "Apply function", run = applyFunction expectFn }
    , { label = "Compose functions", run = composeFunctions expectFn }
    ]


applyFunction : (Src.Module -> Expectation) -> (() -> Expectation)
applyFunction expectFn _ =
    let
        -- apply f x = f x
        applyFn =
            lambdaExpr
                [ pVar "f", pVar "x" ]
                (callExpr (varExpr "f") [ varExpr "x" ])

        def =
            define "apply" [] applyFn

        identity =
            lambdaExpr [ pVar "y" ] (varExpr "y")

        application =
            callExpr (varExpr "apply") [ identity, intExpr 42 ]

        modul =
            makeModule "testValue" (letExpr [ def ] application)
    in
    expectFn modul


composeFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
composeFunctions expectFn _ =
    let
        -- compose f g x = f (g x)
        composeFn =
            lambdaExpr
                [ pVar "f", pVar "g", pVar "x" ]
                (callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ])

        def =
            define "compose" [] composeFn

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "compose"))
    in
    expectFn modul



-- ============================================================================
-- NEGATE
-- ============================================================================


negateCases : (Src.Module -> Expectation) -> List TestCase
negateCases expectFn =
    [ { label = "Negate int", run = negateInt expectFn }
    , { label = "Double negate", run = doubleNegate expectFn }
    ]


negateInt : (Src.Module -> Expectation) -> (() -> Expectation)
negateInt expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (intExpr 42))
    in
    expectFn modul


doubleNegate : (Src.Module -> Expectation) -> (() -> Expectation)
doubleNegate expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (negateExpr (intExpr 42)))
    in
    expectFn modul



-- ============================================================================
-- ABS
-- ============================================================================


absCases : (Src.Module -> Expectation) -> List TestCase
absCases expectFn =
    [ { label = "Abs positive int", run = absPositiveInt expectFn }
    ]


absPositiveInt : (Src.Module -> Expectation) -> (() -> Expectation)
absPositiveInt expectFn _ =
    let
        modul =
            makeModule "testValue" (callExpr (qualVarExpr "Basics" "abs") [ intExpr 5 ])
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC NUMBER FUNCTIONS
-- Tests for polymorphic functions with `number` type variable that contain
-- Int literals in their body. When called with Float, the Int literals must
-- be promoted to Float during monomorphization.
-- ============================================================================


polymorphicNumberCases : (Src.Module -> Expectation) -> List TestCase
polymorphicNumberCases expectFn =
    [ { label = "zabs with Int (baseline)", run = zabsWithInt expectFn }
    , { label = "zabs with Float (Int literal promoted)", run = zabsWithFloat expectFn }
    ]


{-| Define zabs : number -> number with an Int literal 0 in the body.

    zabs : number -> number
    zabs n =
        if n < 0 then
            -n

        else
            n

    testValue =
        zabs 5

When called with Int, this is straightforward - the 0 stays as Int.

-}
zabsWithInt : (Src.Module -> Expectation) -> (() -> Expectation)
zabsWithInt expectFn _ =
    let
        -- Type: number -> number
        zabsType =
            tLambda (tVar "number") (tVar "number")

        -- Body: if n < 0 then -n else n
        zabsBody =
            ifExpr
                (binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 0))
                (negateExpr (varExpr "n"))
                (varExpr "n")

        zabsDef : TypedDef
        zabsDef =
            { name = "zabs"
            , args = [ pVar "n" ]
            , tipe = zabsType
            , body = zabsBody
            }

        -- testValue : Int = zabs 5
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "zabs") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ zabsDef, testValueDef ]
    in
    expectFn modul


{-| Define zabs : number -> number with an Int literal 0 in the body.

    zabs : number -> number
    zabs n =
        if n < 0 then
            -n

        else
            n

    testValue : Float
    testValue =
        zabs 3.14

When called with Float, the 0 literal must be promoted to Float during
monomorphization. This triggers the "Int literal used at Float type" code path.

-}
zabsWithFloat : (Src.Module -> Expectation) -> (() -> Expectation)
zabsWithFloat expectFn _ =
    let
        -- Type: number -> number
        zabsType =
            tLambda (tVar "number") (tVar "number")

        -- Body: if n < 0 then -n else n
        zabsBody =
            ifExpr
                (binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 0))
                (negateExpr (varExpr "n"))
                (varExpr "n")

        zabsDef : TypedDef
        zabsDef =
            { name = "zabs"
            , args = [ pVar "n" ]
            , tipe = zabsType
            , body = zabsBody
            }

        -- testValue : Float = zabs 3.14
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (varExpr "zabs") [ floatExpr 3.14 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ zabsDef, testValueDef ]
    in
    expectFn modul


tLambda : Src.Type -> Src.Type -> Src.Type
tLambda =
    Compiler.AST.SourceBuilder.tLambda


tVar : String -> Src.Type
tVar =
    Compiler.AST.SourceBuilder.tVar


tType : String -> List Src.Type -> Src.Type
tType =
    Compiler.AST.SourceBuilder.tType
