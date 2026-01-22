module Compiler.FunctionTests exposing (expectSuite)

{-| Tests for function expressions: lambdas, calls, partial application.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , define
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , makeModuleWithTypedDefs
        , negateExpr
        , pAnything
        , pRecord
        , pTuple
        , pVar
        , qualVarExpr
        , recordExpr
        , strExpr
        , tLambda
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Function expressions " ++ condStr)
        [ lambdaTests expectFn condStr
        , callTests expectFn condStr
        , partialApplicationTests expectFn condStr
        , nestedFunctionTests expectFn condStr
        , functionWithPatternsTests expectFn condStr
        , higherOrderTests expectFn condStr
        , negateTests expectFn condStr
        , absTests expectFn condStr
        , polymorphicNumberTests expectFn condStr
        ]



-- ============================================================================
-- LAMBDA EXPRESSIONS (8 tests)
-- ============================================================================


lambdaTests : (Src.Module -> Expectation) -> String -> Test
lambdaTests expectFn condStr =
    Test.describe ("Lambda expressions " ++ condStr)
        [ Test.test ("Identity lambda " ++ condStr) (identityLambda expectFn)
        , Test.test ("Const lambda " ++ condStr) (constLambda expectFn)
        , Test.test ("Two-argument lambda " ++ condStr) (twoArgumentLambda expectFn)
        , Test.test ("Three-argument lambda " ++ condStr) (threeArgumentLambda expectFn)
        , Test.test ("Lambda returning tuple " ++ condStr) (lambdaReturningTuple expectFn)
        , Test.test ("Lambda returning record " ++ condStr) (lambdaReturningRecord expectFn)
        , Test.test ("Lambda returning list " ++ condStr) (lambdaReturningList expectFn)
        , Test.test ("Lambda with wildcard pattern " ++ condStr) (lambdaWithWildcard expectFn)
        ]


identityLambda : (Src.Module -> Expectation) -> (() -> Expectation)
identityLambda expectFn _ =
    let
        modul =
            makeModule "testValue" (lambdaExpr [ pVar "x" ] (varExpr "x"))
    in
    expectFn modul


constLambda : (Src.Module -> Expectation) -> (() -> Expectation)
constLambda expectFn _ =
    let
        modul =
            makeModule "testValue" (lambdaExpr [ pVar "x" ] (intExpr 42))
    in
    expectFn modul


twoArgumentLambda : (Src.Module -> Expectation) -> (() -> Expectation)
twoArgumentLambda expectFn _ =
    let
        modul =
            makeModule "testValue" (lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x"))
    in
    expectFn modul


threeArgumentLambda : (Src.Module -> Expectation) -> (() -> Expectation)
threeArgumentLambda expectFn _ =
    let
        modul =
            makeModule "testValue" (lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "b"))
    in
    expectFn modul


lambdaReturningTuple : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaReturningTuple expectFn _ =
    let
        body =
            tupleExpr (varExpr "x") (varExpr "y")

        modul =
            makeModule "testValue" (lambdaExpr [ pVar "x", pVar "y" ] body)
    in
    expectFn modul


lambdaReturningRecord : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaReturningRecord expectFn _ =
    let
        body =
            recordExpr [ ( "value", varExpr "x" ) ]

        modul =
            makeModule "testValue" (lambdaExpr [ pVar "x" ] body)
    in
    expectFn modul


lambdaReturningList : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaReturningList expectFn _ =
    let
        body =
            listExpr [ varExpr "x", varExpr "y" ]

        modul =
            makeModule "testValue" (lambdaExpr [ pVar "x", pVar "y" ] body)
    in
    expectFn modul


lambdaWithWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithWildcard expectFn _ =
    let
        modul =
            makeModule "testValue" (lambdaExpr [ pAnything ] (intExpr 0))
    in
    expectFn modul



-- ============================================================================
-- FUNCTION CALLS (6 tests)
-- ============================================================================


callTests : (Src.Module -> Expectation) -> String -> Test
callTests expectFn condStr =
    Test.describe ("Function calls " ++ condStr)
        [ Test.test ("Call with no args " ++ condStr) (callWithNoArgs expectFn)
        , Test.test ("Call with one int arg " ++ condStr) (callWithOneIntArg expectFn)
        , Test.test ("Call with two args " ++ condStr) (callWithTwoArgs expectFn)
        , Test.test ("Call with three args " ++ condStr) (callWithThreeArgs expectFn)
        , Test.test ("Call with complex args " ++ condStr) (callWithComplexArgs expectFn)
        , Test.test ("Nested calls " ++ condStr) (nestedCalls expectFn)
        ]


callWithNoArgs : (Src.Module -> Expectation) -> (() -> Expectation)
callWithNoArgs expectFn _ =
    let
        fn =
            lambdaExpr [] (intExpr 42)

        def =
            define "f" [] fn

        modul =
            makeModule "testValue" (letExpr [ def ] (callExpr (varExpr "f") []))
    in
    expectFn modul


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


callWithThreeArgs : (Src.Module -> Expectation) -> (() -> Expectation)
callWithThreeArgs expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "x", pVar "y", pVar "z" ] (varExpr "y")

        def =
            define "f" [] fn

        modul =
            makeModule "testValue" (letExpr [ def ] (callExpr (varExpr "f") [ intExpr 1, intExpr 2, intExpr 3 ]))
    in
    expectFn modul


callWithComplexArgs : (Src.Module -> Expectation) -> (() -> Expectation)
callWithComplexArgs expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x")

        def =
            define "f" [] fn

        arg1 =
            tupleExpr (intExpr 1) (intExpr 2)

        arg2 =
            listExpr [ strExpr "a", strExpr "b" ]

        modul =
            makeModule "testValue" (letExpr [ def ] (callExpr (varExpr "f") [ arg1, arg2 ]))
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
-- PARTIAL APPLICATION (4 tests)
-- ============================================================================


partialApplicationTests : (Src.Module -> Expectation) -> String -> Test
partialApplicationTests expectFn condStr =
    Test.describe ("Partial application " ++ condStr)
        [ Test.test ("Partially applied two-arg function " ++ condStr) (partiallyAppliedTwoArg expectFn)
        , Test.test ("Partially applied three-arg function " ++ condStr) (partiallyAppliedThreeArg expectFn)
        , Test.test ("Chained partial application " ++ condStr) (chainedPartialApplication expectFn)
        , Test.test ("Partial application with complex arg " ++ condStr) (partialApplicationWithComplexArg expectFn)
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


partiallyAppliedThreeArg : (Src.Module -> Expectation) -> (() -> Expectation)
partiallyAppliedThreeArg expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial =
            callExpr (varExpr "f") [ intExpr 1, intExpr 2 ]

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


partialApplicationWithComplexArg : (Src.Module -> Expectation) -> (() -> Expectation)
partialApplicationWithComplexArg expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x")

        def =
            define "f" [] fn

        complexArg =
            recordExpr [ ( "value", intExpr 42 ) ]

        partial =
            callExpr (varExpr "f") [ complexArg ]

        modul =
            makeModule "testValue" (letExpr [ def ] partial)
    in
    expectFn modul



-- ============================================================================
-- NESTED FUNCTIONS (6 tests)
-- ============================================================================


nestedFunctionTests : (Src.Module -> Expectation) -> String -> Test
nestedFunctionTests expectFn condStr =
    Test.describe ("Nested functions " ++ condStr)
        [ Test.test ("Lambda returning lambda " ++ condStr) (lambdaReturningLambda expectFn)
        , Test.test ("Triple nested lambda " ++ condStr) (tripleNestedLambda expectFn)
        , Test.test ("Lambda inside let inside lambda " ++ condStr) (lambdaInsideLetInsideLambda expectFn)
        , Test.test ("Multiple lambdas in tuple " ++ condStr) (multipleLambdasInTuple expectFn)
        , Test.test ("Lambda in list " ++ condStr) (lambdaInList expectFn)
        , Test.test ("Lambda in record " ++ condStr) (lambdaInRecord expectFn)
        ]


lambdaReturningLambda : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaReturningLambda expectFn _ =
    let
        inner =
            lambdaExpr [ pVar "y" ] (varExpr "y")

        modul =
            makeModule "testValue" (lambdaExpr [ pVar "x" ] inner)
    in
    expectFn modul


tripleNestedLambda : (Src.Module -> Expectation) -> (() -> Expectation)
tripleNestedLambda expectFn _ =
    let
        innermost =
            lambdaExpr [ pVar "z" ] (varExpr "z")

        middle =
            lambdaExpr [ pVar "y" ] innermost

        modul =
            makeModule "testValue" (lambdaExpr [ pVar "x" ] middle)
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
            makeModule "testValue" (lambdaExpr [ pVar "x" ] body)
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


lambdaInList : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaInList expectFn _ =
    let
        lambda =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        modul =
            makeModule "testValue" (listExpr [ lambda ])
    in
    expectFn modul


lambdaInRecord : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaInRecord expectFn _ =
    let
        lambda =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        modul =
            makeModule "testValue" (recordExpr [ ( "fn", lambda ) ])
    in
    expectFn modul



-- ============================================================================
-- FUNCTIONS WITH PATTERNS (4 tests)
-- ============================================================================


functionWithPatternsTests : (Src.Module -> Expectation) -> String -> Test
functionWithPatternsTests expectFn condStr =
    Test.describe ("Functions with pattern parameters " ++ condStr)
        [ Test.test ("Lambda with tuple pattern " ++ condStr) (lambdaWithTuplePattern expectFn)
        , Test.test ("Lambda with record pattern " ++ condStr) (lambdaWithRecordPattern expectFn)
        , Test.test ("Lambda with mixed patterns " ++ condStr) (lambdaWithMixedPatterns expectFn)
        , Test.test ("Top-level function with patterns " ++ condStr) (topLevelFunctionWithPatterns expectFn)
        ]


lambdaWithTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithTuplePattern expectFn _ =
    let
        pattern =
            pTuple (pVar "x") (pVar "y")

        body =
            tupleExpr (varExpr "y") (varExpr "x")

        modul =
            makeModule "testValue" (lambdaExpr [ pattern ] body)
    in
    expectFn modul


lambdaWithRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithRecordPattern expectFn _ =
    let
        pattern =
            pRecord [ "x", "y" ]

        body =
            varExpr "x"

        modul =
            makeModule "testValue" (lambdaExpr [ pattern ] body)
    in
    expectFn modul


lambdaWithMixedPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithMixedPatterns expectFn _ =
    let
        modul =
            makeModule "testValue"
                (lambdaExpr
                    [ pVar "a"
                    , pTuple (pVar "b") (pVar "c")
                    , pAnything
                    ]
                    (varExpr "b")
                )
    in
    expectFn modul


topLevelFunctionWithPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
topLevelFunctionWithPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "swap", [ pTuple (pVar "a") (pVar "b") ], tupleExpr (varExpr "b") (varExpr "a") )
                ]
    in
    expectFn modul



-- ============================================================================
-- HIGHER-ORDER FUNCTIONS (3 tests)
-- ============================================================================


higherOrderTests : (Src.Module -> Expectation) -> String -> Test
higherOrderTests expectFn condStr =
    Test.describe ("Higher-order functions " ++ condStr)
        [ Test.test ("Apply function " ++ condStr) (applyFunction expectFn)
        , Test.test ("Compose functions " ++ condStr) (composeFunctions expectFn)
        , Test.test ("Function returning function " ++ condStr) (functionReturningFunction expectFn)
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


functionReturningFunction : (Src.Module -> Expectation) -> (() -> Expectation)
functionReturningFunction expectFn _ =
    let
        -- makeAdder n = \x -> x (returns a function)
        makeAdder =
            lambdaExpr
                [ pVar "n" ]
                (lambdaExpr [ pVar "x" ] (varExpr "x"))

        def =
            define "makeAdder" [] makeAdder

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "makeAdder"))
    in
    expectFn modul



-- ============================================================================
-- NEGATE (3 tests)
-- ============================================================================


negateTests : (Src.Module -> Expectation) -> String -> Test
negateTests expectFn condStr =
    Test.describe ("Negate expressions " ++ condStr)
        [ Test.test ("Negate int " ++ condStr) (negateInt expectFn)
        , Test.test ("Negate float " ++ condStr) (negateFloat expectFn)
        , Test.test ("Double negate " ++ condStr) (doubleNegate expectFn)
        ]


negateInt : (Src.Module -> Expectation) -> (() -> Expectation)
negateInt expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (intExpr 42))
    in
    expectFn modul


negateFloat : (Src.Module -> Expectation) -> (() -> Expectation)
negateFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (floatExpr 3.14))
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
-- ABS (6 tests)
-- ============================================================================


absTests : (Src.Module -> Expectation) -> String -> Test
absTests expectFn condStr =
    Test.describe ("Abs expressions " ++ condStr)
        [ Test.test ("Abs positive int " ++ condStr) (absPositiveInt expectFn)
        , Test.test ("Abs negative int " ++ condStr) (absNegativeInt expectFn)
        , Test.test ("Abs zero int " ++ condStr) (absZeroInt expectFn)
        , Test.test ("Abs positive float " ++ condStr) (absPositiveFloat expectFn)
        , Test.test ("Abs negative float " ++ condStr) (absNegativeFloat expectFn)
        , Test.test ("Abs zero float " ++ condStr) (absZeroFloat expectFn)
        ]


absPositiveInt : (Src.Module -> Expectation) -> (() -> Expectation)
absPositiveInt expectFn _ =
    let
        modul =
            makeModule "testValue" (callExpr (qualVarExpr "Basics" "abs") [ intExpr 5 ])
    in
    expectFn modul


absNegativeInt : (Src.Module -> Expectation) -> (() -> Expectation)
absNegativeInt expectFn _ =
    let
        modul =
            makeModule "testValue" (callExpr (qualVarExpr "Basics" "abs") [ negateExpr (intExpr 5) ])
    in
    expectFn modul


absZeroInt : (Src.Module -> Expectation) -> (() -> Expectation)
absZeroInt expectFn _ =
    let
        modul =
            makeModule "testValue" (callExpr (qualVarExpr "Basics" "abs") [ intExpr 0 ])
    in
    expectFn modul


absPositiveFloat : (Src.Module -> Expectation) -> (() -> Expectation)
absPositiveFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (callExpr (qualVarExpr "Basics" "abs") [ floatExpr 3.14 ])
    in
    expectFn modul


absNegativeFloat : (Src.Module -> Expectation) -> (() -> Expectation)
absNegativeFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (callExpr (qualVarExpr "Basics" "abs") [ negateExpr (floatExpr 3.14) ])
    in
    expectFn modul


absZeroFloat : (Src.Module -> Expectation) -> (() -> Expectation)
absZeroFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (callExpr (qualVarExpr "Basics" "abs") [ floatExpr 0.0 ])
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC NUMBER FUNCTIONS (3 tests)
-- Tests for polymorphic functions with `number` type variable that contain
-- Int literals in their body. When called with Float, the Int literals must
-- be promoted to Float during monomorphization.
-- ============================================================================


polymorphicNumberTests : (Src.Module -> Expectation) -> String -> Test
polymorphicNumberTests expectFn condStr =
    Test.describe ("Polymorphic number functions " ++ condStr)
        [ Test.test ("zabs with Int (baseline) " ++ condStr) (zabsWithInt expectFn)
        , Test.test ("zabs with Float (Int literal promoted) " ++ condStr) (zabsWithFloat expectFn)
        , Test.test ("zabs with zero Float " ++ condStr) (zabsWithZeroFloat expectFn)
        ]


{-| Define zabs : number -> number with an Int literal 0 in the body.

    zabs : number -> number
    zabs n =
        if n < 0 then
            -n
        else
            n

    testValue = zabs 5

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
    testValue = zabs 3.14

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


{-| Similar to zabsWithFloat but with 0.0 as argument.

    testValue : Float
    testValue = zabs 0.0

This also triggers Float specialization.

-}
zabsWithZeroFloat : (Src.Module -> Expectation) -> (() -> Expectation)
zabsWithZeroFloat expectFn _ =
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

        -- testValue : Float = zabs 0.0
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (varExpr "zabs") [ floatExpr 0.0 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ zabsDef, testValueDef ]
    in
    expectFn modul
