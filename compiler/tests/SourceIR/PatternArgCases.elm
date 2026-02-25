module SourceIR.PatternArgCases exposing (expectSuite)

{-| Tests for function arguments with various patterns.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , intExpr
        , lambdaExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pCtor
        , pInt
        , pList
        , pRecord
        , pStr
        , pTuple
        , pTuple3
        , pUnit
        , pVar
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
    Test.test ("Pattern argument tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    variablePatternCases expectFn
        ++ wildcardPatternCases expectFn
        ++ tuplePatternCases expectFn
        ++ recordPatternCases expectFn
        ++ listPatternCases expectFn
        ++ literalPatternCases expectFn
        ++ nestedPatternCases expectFn
        ++ multiArgPatternCases expectFn
        ++ customTypePatternCases expectFn



-- ============================================================================
-- VARIABLE PATTERNS (6 tests)
-- ============================================================================


variablePatternCases : (Src.Module -> Expectation) -> List TestCase
variablePatternCases expectFn =
    [ { label = "Single variable pattern", run = singleVariablePattern expectFn }
    , { label = "Two variable patterns", run = twoVariablePatterns expectFn }
    , { label = "Three variable patterns", run = threeVariablePatterns expectFn }
    , { label = "Variable pattern returning tuple", run = variablePatternReturningTuple expectFn }
    , { label = "Variable pattern returning list", run = variablePatternReturningList expectFn }
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



-- ============================================================================
-- WILDCARD PATTERNS (4 tests)
-- ============================================================================


wildcardPatternCases : (Src.Module -> Expectation) -> List TestCase
wildcardPatternCases expectFn =
    [ { label = "Single wildcard pattern", run = singleWildcardPattern expectFn }
    , { label = "Wildcard with variable", run = wildcardWithVariable expectFn }
    , { label = "Multiple wildcards", run = multipleWildcards expectFn }
    , { label = "Wildcard in lambda", run = wildcardInLambda expectFn }
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


tuplePatternCases : (Src.Module -> Expectation) -> List TestCase
tuplePatternCases expectFn =
    [ { label = "2-tuple pattern", run = tuple2Pattern expectFn }
    , { label = "3-tuple pattern", run = tuple3Pattern expectFn }
    , { label = "Tuple pattern with wildcard", run = tuplePatternWithWildcard expectFn }
    , { label = "Nested tuple pattern", run = nestedTuplePattern expectFn }
    , { label = "Tuple pattern in lambda", run = tuplePatternInLambda expectFn }
    , { label = "Multiple tuple pattern args", run = multipleTuplePatternArgs expectFn }
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


recordPatternCases : (Src.Module -> Expectation) -> List TestCase
recordPatternCases expectFn =
    [ { label = "Single field record pattern", run = singleFieldRecordPattern expectFn }
    , { label = "Multi-field record pattern", run = multiFieldRecordPattern expectFn }
    , { label = "Record pattern in lambda", run = recordPatternInLambda expectFn }
    , { label = "Record pattern with many fields", run = recordPatternWithManyFields expectFn }
    , { label = "Multiple record pattern args", run = multipleRecordPatternArgs expectFn }
    , { label = "Record pattern with variable", run = recordPatternWithVariable expectFn }
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


listPatternCases : (Src.Module -> Expectation) -> List TestCase
listPatternCases expectFn =
    [ { label = "Cons pattern", run = consPattern expectFn }
    , { label = "Fixed list pattern", run = fixedListPattern expectFn }
    , { label = "Nested cons pattern", run = nestedConsPattern expectFn }
    , { label = "List pattern in lambda", run = listPatternInLambda expectFn }
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


literalPatternCases : (Src.Module -> Expectation) -> List TestCase
literalPatternCases expectFn =
    [ { label = "Int literal pattern", run = intLiteralPattern expectFn }
    , { label = "String literal pattern", run = stringLiteralPattern expectFn }
    , { label = "Unit pattern", run = unitPattern expectFn }
    , { label = "Multiple literal patterns", run = multipleLiteralPatterns expectFn }
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


nestedPatternCases : (Src.Module -> Expectation) -> List TestCase
nestedPatternCases expectFn =
    [ { label = "Deeply nested tuple", run = deeplyNestedTuplePattern expectFn }
    , { label = "Mixed nested patterns", run = mixedNestedPatterns expectFn }
    , { label = "Triple nested patterns", run = tripleNestedPatterns expectFn }
    , { label = "Nested with wildcards", run = nestedWithWildcards expectFn }
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


multiArgPatternCases : (Src.Module -> Expectation) -> List TestCase
multiArgPatternCases expectFn =
    [ { label = "Five args with mixed patterns", run = fiveArgsWithMixedPatterns expectFn }
    , { label = "All same pattern type", run = allSamePatternType expectFn }
    , { label = "Alternating patterns", run = alternatingPatterns expectFn }
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
-- CUSTOM TYPE PATTERNS (2 tests)
-- ============================================================================


customTypePatternCases : (Src.Module -> Expectation) -> List TestCase
customTypePatternCases expectFn =
    [ { label = "Custom type pattern in function argument", run = customTypePatternInFunctionArg expectFn }
    , { label = "Custom type pattern with multiple extractors", run = customTypePatternMultipleExtractors expectFn }
    ]


{-| Tests pattern matching on custom types in function arguments.
Corresponds to E2E test: CustomTypePatternTest.elm

    type Person
        = Person Int Int

    getId (Person id _) =
        id

    getAge (Person _ age) =
        age

Note: Using Int instead of String to match what the compiler currently supports.

-}
customTypePatternInFunctionArg : (Src.Module -> Expectation) -> (() -> Expectation)
customTypePatternInFunctionArg expectFn _ =
    let
        -- Define the Person union type
        personUnion : UnionDef
        personUnion =
            { name = "Person"
            , args = []
            , ctors =
                [ { name = "Person", args = [ tType "Int" [], tType "Int" [] ] }
                ]
            }

        -- Define the getId function
        -- getId : Person -> Int
        -- getId (Person id _) = id
        getIdFn : TypedDef
        getIdFn =
            { name = "getId"
            , args = [ pCtor "Person" [ pVar "id", pAnything ] ]
            , tipe = tLambda (tType "Person" []) (tType "Int" [])
            , body = varExpr "id"
            }

        -- Define the getAge function
        -- getAge : Person -> Int
        -- getAge (Person _ age) = age
        getAgeFn : TypedDef
        getAgeFn =
            { name = "getAge"
            , args = [ pCtor "Person" [ pAnything, pVar "age" ] ]
            , tipe = tLambda (tType "Person" []) (tType "Int" [])
            , body = varExpr "age"
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ getIdFn, getAgeFn ] [ personUnion ] []
    in
    expectFn modul


{-| Tests pattern matching on custom types with multiple constructors in function arguments.
-}
customTypePatternMultipleExtractors : (Src.Module -> Expectation) -> (() -> Expectation)
customTypePatternMultipleExtractors expectFn _ =
    let
        -- Define a Box type with a single field
        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = []
            , ctors =
                [ { name = "Box", args = [ tType "Int" [] ] }
                ]
            }

        -- Define the unbox function
        -- unbox : Box -> Int
        -- unbox (Box x) = x
        unboxFn : TypedDef
        unboxFn =
            { name = "unbox"
            , args = [ pCtor "Box" [ pVar "x" ] ]
            , tipe = tLambda (tType "Box" []) (tType "Int" [])
            , body = varExpr "x"
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ unboxFn ] [ boxUnion ] []
    in
    expectFn modul
