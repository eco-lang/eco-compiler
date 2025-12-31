module Compiler.PatternArgTests exposing (expectSuite)

{-| Tests for function arguments with various patterns.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , pAnything
        , pCons
        , pInt
        , pList
        , pRecord
        , pStr
        , pTuple
        , pTuple3
        , pUnit
        , pVar
        , strExpr
        , tupleExpr
        , varExpr
        )
import Expect exposing (Expectation)
import Fuzz
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Pattern argument tests " ++ condStr)
        [ variablePatternTests expectFn condStr
        , wildcardPatternTests expectFn condStr
        , tuplePatternTests expectFn condStr
        , recordPatternTests expectFn condStr
        , listPatternTests expectFn condStr
        , literalPatternTests expectFn condStr
        , nestedPatternTests expectFn condStr
        , multiArgPatternTests expectFn condStr
        , patternFuzzTests expectFn condStr
        ]



-- ============================================================================
-- VARIABLE PATTERNS (6 tests)
-- ============================================================================


variablePatternTests : (Src.Module -> Expectation) -> String -> Test
variablePatternTests expectFn condStr =
    Test.describe ("Variable patterns " ++ condStr)
        [ Test.test ("Single variable pattern " ++ condStr) (singleVariablePattern expectFn)
        , Test.test ("Two variable patterns " ++ condStr) (twoVariablePatterns expectFn)
        , Test.test ("Three variable patterns " ++ condStr) (threeVariablePatterns expectFn)
        , Test.test ("Variable pattern returning tuple " ++ condStr) (variablePatternReturningTuple expectFn)
        , Test.test ("Variable pattern returning list " ++ condStr) (variablePatternReturningList expectFn)
        , Test.test ("Multiple functions with variable patterns " ++ condStr) (multipleFunctionsWithVariablePatterns expectFn)
        ]


singleVariablePattern : (Src.Module -> Expectation) -> (() -> Expectation)
singleVariablePattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "identity", [ pVar "x" ], varExpr "x" )
                ]
    in
    expectFn modul


twoVariablePatterns : (Src.Module -> Expectation) -> (() -> Expectation)
twoVariablePatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "first", [ pVar "x", pVar "y" ], varExpr "x" )
                ]
    in
    expectFn modul


threeVariablePatterns : (Src.Module -> Expectation) -> (() -> Expectation)
threeVariablePatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "second", [ pVar "a", pVar "b", pVar "c" ], varExpr "b" )
                ]
    in
    expectFn modul


variablePatternReturningTuple : (Src.Module -> Expectation) -> (() -> Expectation)
variablePatternReturningTuple expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "swap", [ pVar "x", pVar "y" ], tupleExpr (varExpr "y") (varExpr "x") )
                ]
    in
    expectFn modul


variablePatternReturningList : (Src.Module -> Expectation) -> (() -> Expectation)
variablePatternReturningList expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "toList", [ pVar "x" ], listExpr [ varExpr "x" ] )
                ]
    in
    expectFn modul


multipleFunctionsWithVariablePatterns : (Src.Module -> Expectation) -> (() -> Expectation)
multipleFunctionsWithVariablePatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "f", [ pVar "x" ], varExpr "x" )
                , ( "g", [ pVar "y" ], varExpr "y" )
                ]
    in
    expectFn modul



-- ============================================================================
-- WILDCARD PATTERNS (4 tests)
-- ============================================================================


wildcardPatternTests : (Src.Module -> Expectation) -> String -> Test
wildcardPatternTests expectFn condStr =
    Test.describe ("Wildcard patterns " ++ condStr)
        [ Test.test ("Single wildcard pattern " ++ condStr) (singleWildcardPattern expectFn)
        , Test.test ("Wildcard with variable " ++ condStr) (wildcardWithVariable expectFn)
        , Test.test ("Multiple wildcards " ++ condStr) (multipleWildcards expectFn)
        , Test.test ("Wildcard in lambda " ++ condStr) (wildcardInLambda expectFn)
        ]


singleWildcardPattern : (Src.Module -> Expectation) -> (() -> Expectation)
singleWildcardPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "const", [ pAnything ], intExpr 42 )
                ]
    in
    expectFn modul


wildcardWithVariable : (Src.Module -> Expectation) -> (() -> Expectation)
wildcardWithVariable expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "const", [ pVar "x", pAnything ], varExpr "x" )
                ]
    in
    expectFn modul


multipleWildcards : (Src.Module -> Expectation) -> (() -> Expectation)
multipleWildcards expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "zero", [ pAnything, pAnything, pAnything ], intExpr 0 )
                ]
    in
    expectFn modul


wildcardInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
wildcardInLambda expectFn _ =
    let
        fn =
            lambdaExpr [ pAnything ] (intExpr 0)

        modul =
            makeModule "testValue" fn
    in
    expectFn modul



-- ============================================================================
-- TUPLE PATTERNS (6 tests)
-- ============================================================================


tuplePatternTests : (Src.Module -> Expectation) -> String -> Test
tuplePatternTests expectFn condStr =
    Test.describe ("Tuple patterns " ++ condStr)
        [ Test.test ("2-tuple pattern " ++ condStr) (tuple2Pattern expectFn)
        , Test.test ("3-tuple pattern " ++ condStr) (tuple3Pattern expectFn)
        , Test.test ("Tuple pattern with wildcard " ++ condStr) (tuplePatternWithWildcard expectFn)
        , Test.test ("Nested tuple pattern " ++ condStr) (nestedTuplePattern expectFn)
        , Test.test ("Tuple pattern in lambda " ++ condStr) (tuplePatternInLambda expectFn)
        , Test.test ("Multiple tuple pattern args " ++ condStr) (multipleTuplePatternArgs expectFn)
        ]


tuple2Pattern : (Src.Module -> Expectation) -> (() -> Expectation)
tuple2Pattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "fst", [ pTuple (pVar "x") (pVar "y") ], varExpr "x" )
                ]
    in
    expectFn modul


tuple3Pattern : (Src.Module -> Expectation) -> (() -> Expectation)
tuple3Pattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "snd3", [ pTuple3 (pVar "a") (pVar "b") (pVar "c") ], varExpr "b" )
                ]
    in
    expectFn modul


tuplePatternWithWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
tuplePatternWithWildcard expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "snd", [ pTuple pAnything (pVar "y") ], varExpr "y" )
                ]
    in
    expectFn modul


nestedTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
nestedTuplePattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "deep", [ pTuple (pTuple (pVar "a") (pVar "b")) (pVar "c") ], varExpr "a" )
                ]
    in
    expectFn modul


tuplePatternInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
tuplePatternInLambda expectFn _ =
    let
        fn =
            lambdaExpr [ pTuple (pVar "x") (pVar "y") ] (varExpr "x")

        modul =
            makeModule "testValue" fn
    in
    expectFn modul


multipleTuplePatternArgs : (Src.Module -> Expectation) -> (() -> Expectation)
multipleTuplePatternArgs expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "addPairs"
                  , [ pTuple (pVar "a") (pVar "b"), pTuple (pVar "c") (pVar "d") ]
                  , tupleExpr (varExpr "a") (varExpr "c")
                  )
                ]
    in
    expectFn modul



-- ============================================================================
-- RECORD PATTERNS (6 tests)
-- ============================================================================


recordPatternTests : (Src.Module -> Expectation) -> String -> Test
recordPatternTests expectFn condStr =
    Test.describe ("Record patterns " ++ condStr)
        [ Test.test ("Single field record pattern " ++ condStr) (singleFieldRecordPattern expectFn)
        , Test.test ("Multi-field record pattern " ++ condStr) (multiFieldRecordPattern expectFn)
        , Test.test ("Record pattern in lambda " ++ condStr) (recordPatternInLambda expectFn)
        , Test.test ("Record pattern with many fields " ++ condStr) (recordPatternWithManyFields expectFn)
        , Test.test ("Multiple record pattern args " ++ condStr) (multipleRecordPatternArgs expectFn)
        , Test.test ("Record pattern with variable " ++ condStr) (recordPatternWithVariable expectFn)
        ]


singleFieldRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
singleFieldRecordPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "getX", [ pRecord [ "x" ] ], varExpr "x" )
                ]
    in
    expectFn modul


multiFieldRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
multiFieldRecordPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "getXY", [ pRecord [ "x", "y" ] ], tupleExpr (varExpr "x") (varExpr "y") )
                ]
    in
    expectFn modul


recordPatternInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
recordPatternInLambda expectFn _ =
    let
        fn =
            lambdaExpr [ pRecord [ "name" ] ] (varExpr "name")

        modul =
            makeModule "testValue" fn
    in
    expectFn modul


recordPatternWithManyFields : (Src.Module -> Expectation) -> (() -> Expectation)
recordPatternWithManyFields expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "getAll", [ pRecord [ "a", "b", "c", "d", "e" ] ], varExpr "a" )
                ]
    in
    expectFn modul


multipleRecordPatternArgs : (Src.Module -> Expectation) -> (() -> Expectation)
multipleRecordPatternArgs expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "combine"
                  , [ pRecord [ "x" ], pRecord [ "y" ] ]
                  , tupleExpr (varExpr "x") (varExpr "y")
                  )
                ]
    in
    expectFn modul


recordPatternWithVariable : (Src.Module -> Expectation) -> (() -> Expectation)
recordPatternWithVariable expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "extract", [ pRecord [ "value" ], pVar "default" ], varExpr "value" )
                ]
    in
    expectFn modul



-- ============================================================================
-- LIST PATTERNS (4 tests)
-- ============================================================================


listPatternTests : (Src.Module -> Expectation) -> String -> Test
listPatternTests expectFn condStr =
    Test.describe ("List patterns " ++ condStr)
        [ Test.test ("Cons pattern " ++ condStr) (consPattern expectFn)
        , Test.test ("Fixed list pattern " ++ condStr) (fixedListPattern expectFn)
        , Test.test ("Nested cons pattern " ++ condStr) (nestedConsPattern expectFn)
        , Test.test ("List pattern in lambda " ++ condStr) (listPatternInLambda expectFn)
        ]


consPattern : (Src.Module -> Expectation) -> (() -> Expectation)
consPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "head", [ pCons (pVar "h") (pVar "t") ], varExpr "h" )
                ]
    in
    expectFn modul


fixedListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
fixedListPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "firstTwo", [ pList [ pVar "a", pVar "b" ] ], tupleExpr (varExpr "a") (varExpr "b") )
                ]
    in
    expectFn modul


nestedConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
nestedConsPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "secondElem", [ pCons pAnything (pCons (pVar "x") pAnything) ], varExpr "x" )
                ]
    in
    expectFn modul


listPatternInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
listPatternInLambda expectFn _ =
    let
        fn =
            lambdaExpr [ pCons (pVar "x") pAnything ] (varExpr "x")

        modul =
            makeModule "testValue" fn
    in
    expectFn modul



-- ============================================================================
-- LITERAL PATTERNS (4 tests)
-- ============================================================================


literalPatternTests : (Src.Module -> Expectation) -> String -> Test
literalPatternTests expectFn condStr =
    Test.describe ("Literal patterns " ++ condStr)
        [ Test.test ("Int literal pattern " ++ condStr) (intLiteralPattern expectFn)
        , Test.test ("String literal pattern " ++ condStr) (stringLiteralPattern expectFn)
        , Test.test ("Unit pattern " ++ condStr) (unitPattern expectFn)
        , Test.test ("Multiple literal patterns " ++ condStr) (multipleLiteralPatterns expectFn)
        ]


intLiteralPattern : (Src.Module -> Expectation) -> (() -> Expectation)
intLiteralPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "isZero", [ pInt 0 ], strExpr "zero" )
                ]
    in
    expectFn modul


stringLiteralPattern : (Src.Module -> Expectation) -> (() -> Expectation)
stringLiteralPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "greet", [ pStr "hello" ], strExpr "hi" )
                ]
    in
    expectFn modul


unitPattern : (Src.Module -> Expectation) -> (() -> Expectation)
unitPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "unit", [ pUnit ], intExpr 0 )
                ]
    in
    expectFn modul


multipleLiteralPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
multipleLiteralPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "match", [ pInt 0, pStr "" ], intExpr 0 )
                ]
    in
    expectFn modul



-- ============================================================================
-- NESTED PATTERNS (4 tests)
-- ============================================================================


nestedPatternTests : (Src.Module -> Expectation) -> String -> Test
nestedPatternTests expectFn condStr =
    Test.describe ("Nested patterns " ++ condStr)
        [ Test.test ("Deeply nested tuple " ++ condStr) (deeplyNestedTuplePattern expectFn)
        , Test.test ("Mixed nested patterns " ++ condStr) (mixedNestedPatterns expectFn)
        , Test.test ("Triple nested patterns " ++ condStr) (tripleNestedPatterns expectFn)
        , Test.test ("Nested with wildcards " ++ condStr) (nestedWithWildcards expectFn)
        ]


deeplyNestedTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedTuplePattern expectFn _ =
    let
        pattern =
            pTuple
                (pTuple (pVar "a") (pVar "b"))
                (pTuple (pVar "c") (pVar "d"))

        modul =
            makeModuleWithDefs "Test"
                [ ( "extract", [ pattern ], varExpr "a" )
                ]
    in
    expectFn modul


mixedNestedPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
mixedNestedPatterns expectFn _ =
    let
        pattern =
            pTuple (pRecord [ "x" ]) (pCons (pVar "h") pAnything)

        modul =
            makeModuleWithDefs "Test"
                [ ( "mixed", [ pattern ], tupleExpr (varExpr "x") (varExpr "h") )
                ]
    in
    expectFn modul


tripleNestedPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
tripleNestedPatterns expectFn _ =
    let
        pattern =
            pTuple3
                (pTuple (pVar "a") (pVar "b"))
                (pRecord [ "x", "y" ])
                (pCons (pVar "h") (pVar "t"))

        modul =
            makeModuleWithDefs "Test"
                [ ( "complex", [ pattern ], varExpr "a" )
                ]
    in
    expectFn modul


nestedWithWildcards : (Src.Module -> Expectation) -> (() -> Expectation)
nestedWithWildcards expectFn _ =
    let
        pattern =
            pTuple
                (pTuple (pVar "x") pAnything)
                (pTuple pAnything (pVar "y"))

        modul =
            makeModuleWithDefs "Test"
                [ ( "corners", [ pattern ], tupleExpr (varExpr "x") (varExpr "y") )
                ]
    in
    expectFn modul



-- ============================================================================
-- MULTI-ARG PATTERNS (4 tests)
-- ============================================================================


multiArgPatternTests : (Src.Module -> Expectation) -> String -> Test
multiArgPatternTests expectFn condStr =
    Test.describe ("Multiple argument patterns " ++ condStr)
        [ Test.test ("Five args with mixed patterns " ++ condStr) (fiveArgsWithMixedPatterns expectFn)
        , Test.test ("All same pattern type " ++ condStr) (allSamePatternType expectFn)
        , Test.test ("All wildcards " ++ condStr) (allWildcards expectFn)
        , Test.test ("Alternating patterns " ++ condStr) (alternatingPatterns expectFn)
        ]


fiveArgsWithMixedPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
fiveArgsWithMixedPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "fiveArgs"
                  , [ pVar "a", pTuple (pVar "b") (pVar "c"), pRecord [ "d" ], pAnything, pVar "e" ]
                  , varExpr "a"
                  )
                ]
    in
    expectFn modul


allSamePatternType : (Src.Module -> Expectation) -> (() -> Expectation)
allSamePatternType expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "allTuples"
                  , [ pTuple (pVar "a") (pVar "b")
                    , pTuple (pVar "c") (pVar "d")
                    , pTuple (pVar "e") (pVar "f")
                    ]
                  , varExpr "a"
                  )
                ]
    in
    expectFn modul


allWildcards : (Src.Module -> Expectation) -> (() -> Expectation)
allWildcards expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "ignoreAll", [ pAnything, pAnything, pAnything, pAnything ], intExpr 0 )
                ]
    in
    expectFn modul


alternatingPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
alternatingPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "alternate"
                  , [ pVar "a", pAnything, pVar "b", pAnything, pVar "c" ]
                  , listExpr [ varExpr "a", varExpr "b", varExpr "c" ]
                  )
                ]
    in
    expectFn modul



-- ============================================================================
-- FUZZ TESTS (2 tests)
-- ============================================================================


patternFuzzTests : (Src.Module -> Expectation) -> String -> Test
patternFuzzTests expectFn condStr =
    Test.describe ("Fuzzed pattern tests " ++ condStr)
        [ Test.fuzz Fuzz.int ("Function with int pattern called with fuzzed value " ++ condStr) (functionWithIntPatternFuzzed expectFn)
        , Test.fuzz2 Fuzz.int Fuzz.int ("Function with tuple pattern called with fuzzed values " ++ condStr) (functionWithTuplePatternFuzzed expectFn)
        ]


functionWithIntPatternFuzzed : (Src.Module -> Expectation) -> (Int -> Expectation)
functionWithIntPatternFuzzed expectFn n =
    let
        fn =
            define "f" [ pVar "x" ] (varExpr "x")

        call =
            callExpr (varExpr "f") [ intExpr n ]

        modul =
            makeModule "testValue" (letExpr [ fn ] call)
    in
    expectFn modul


functionWithTuplePatternFuzzed : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
functionWithTuplePatternFuzzed expectFn a b =
    let
        fn =
            define "swap" [ pTuple (pVar "x") (pVar "y") ] (tupleExpr (varExpr "y") (varExpr "x"))

        call =
            callExpr (varExpr "swap") [ tupleExpr (intExpr a) (intExpr b) ]

        modul =
            makeModule "testValue" (letExpr [ fn ] call)
    in
    expectFn modul
