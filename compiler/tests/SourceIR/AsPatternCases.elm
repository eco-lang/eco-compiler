module SourceIR.AsPatternCases exposing (expectSuite)

{-| Source programs that bind names with as-patterns, for a caller to run
through whichever compiler stage it is testing.

An as-pattern, `pattern as name`, matches `pattern` and also binds `name` to
the whole of the value matched, so it introduces one more variable than the
pattern inside it. These programs exist so that a stage under test meets that
extra binding on each of the kinds of pattern listed below, and in a function
argument, a lambda, a let-destructuring and a case branch.

This module asserts nothing itself. `expectSuite` runs the programs in order as
one test through `Compiler.BulkCheck.bulkCheck`, handing each to the caller's
expectation function and stopping at the first that fails; what passing means
is up to that function.

Every program is a module named `Test` built with `Compiler.AST.SourceBuilder`,
with no type annotations, importing only `Basics` and `List`. Most define a
function whose arguments use the as-pattern, and a `testValue` that calls it on
values built from integer and string literals; the rest put the pattern in a
lambda, a `let` or a `case` inside `testValue` itself. The list and cons
argument patterns are refutable: they do not match every list.

The programs, by group:

  - Simple: an alias on a variable, on a wildcard, on each of a function's two
    arguments, and on a lambda's argument.
  - Tuples: an alias on a pair, on a triple, on each element of a pair, and on
    a pair whose first element is a pair.
  - Records: an alias on a two-field record pattern, on each of two one-field
    record arguments, and on a four-field record pattern.
  - Lists: an alias on a cons pattern, on a two-element list pattern, on the
    head and on the tail of a cons pattern, and on a cons pattern whose tail is
    itself a cons pattern.
  - Nesting: an alias on an alias, an alias on a pair nested in a pair, and an
    alias on a pair of a record pattern and an aliased cons pattern.
  - Definitions: an alias in a let-destructuring, and in the argument of a
    function defined in a `let`.
  - Case: an alias in a case branch.

Among what is not tested: an alias on a constructor or literal pattern, an
alias in an annotated definition, and an alias whose use fails to type-check
(programs of that kind are in `SourceIR.TypeCheckFailsCases`).

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , caseExpr
        , define
        , destruct
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , pAlias
        , pAnything
        , pCons
        , pList
        , pRecord
        , pTuple
        , pTuple3
        , pVar
        , recordExpr
        , strExpr
        , tuple3Expr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "As-pattern tests " followed by `condStr`, that
runs `expectFn` on the programs in this module in order and passes when all of
them pass. It stops at the first program that fails and reports the failure
under that case's label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("As-pattern tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, each running `expectFn` on its
program, group by group in the order the module docstring lists them.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ simpleAliasCases expectFn
        , tupleAliasCases expectFn
        , recordAliasCases expectFn
        , listAliasCases expectFn
        , nestedAliasCases expectFn
        , aliasInFunctionsCases expectFn
        , aliasAdditionalCases expectFn
        ]



-- ============================================================================
-- SIMPLE ALIAS
-- ============================================================================


{-| Returns the cases that alias a variable, a wildcard, each of two
arguments, and a lambda's argument.
-}
simpleAliasCases : (Src.Module -> Expectation) -> List TestCase
simpleAliasCases expectFn =
    [ { label = "Alias on variable", run = aliasOnVariable expectFn }
    , { label = "Alias on wildcard", run = aliasOnWildcard expectFn }
    , { label = "Multiple aliases", run = multipleAliases expectFn }
    , { label = "Alias in lambda", run = aliasInLambda expectFn }
    ]


{-| Runs `expectFn` on `dup (x as y) = ( x, y )` with `testValue = dup 1`.
-}
aliasOnVariable : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnVariable expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "dup", [ pAlias (pVar "x") "y" ], tupleExpr (varExpr "x") (varExpr "y") )
                , ( "testValue", [], callExpr (varExpr "dup") [ intExpr 1 ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `capture (_ as x) = x` with `testValue = capture 1`.
-}
aliasOnWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnWildcard expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "capture", [ pAlias pAnything "x" ], varExpr "x" )
                , ( "testValue", [], callExpr (varExpr "capture") [ intExpr 1 ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `both (a as x) (b as y) = ( x, y )` with
`testValue = both 1 "a"`.
-}
multipleAliases : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAliases expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "both"
                  , [ pAlias (pVar "a") "x", pAlias (pVar "b") "y" ]
                  , tupleExpr (varExpr "x") (varExpr "y")
                  )
                , ( "testValue", [], callExpr (varExpr "both") [ intExpr 1, strExpr "a" ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `testValue = (\(x as whole) -> ( x, whole )) 1`.
-}
aliasInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
aliasInLambda expectFn _ =
    let
        fn =
            lambdaExpr [ pAlias (pVar "x") "whole" ] (tupleExpr (varExpr "x") (varExpr "whole"))

        modul =
            makeModule "testValue" (callExpr fn [ intExpr 1 ])
    in
    expectFn modul



-- ============================================================================
-- TUPLE ALIAS
-- ============================================================================


{-| Returns the cases that alias a pair, a triple, each element of a pair,
and a pair holding a pair.
-}
tupleAliasCases : (Src.Module -> Expectation) -> List TestCase
tupleAliasCases expectFn =
    [ { label = "Alias on 2-tuple", run = aliasOn2Tuple expectFn }
    , { label = "Alias on 3-tuple", run = aliasOn3Tuple expectFn }
    , { label = "Nested alias in tuple", run = nestedAliasInTuple expectFn }
    , { label = "Alias on nested tuple", run = aliasOnNestedTuple expectFn }
    ]


{-| Runs `expectFn` on `withPair (( a, b ) as pair) = ( pair, a )` with
`testValue = withPair ( 1, "a" )`.
-}
aliasOn2Tuple : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOn2Tuple expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "withPair"
                  , [ pAlias (pTuple (pVar "a") (pVar "b")) "pair" ]
                  , tupleExpr (varExpr "pair") (varExpr "a")
                  )
                , ( "testValue", [], callExpr (varExpr "withPair") [ tupleExpr (intExpr 1) (strExpr "a") ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `withTriple (( a, b, c ) as triple) = triple` with
`testValue = withTriple ( 1, "a", 2 )`.
-}
aliasOn3Tuple : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOn3Tuple expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "withTriple"
                  , [ pAlias (pTuple3 (pVar "a") (pVar "b") (pVar "c")) "triple" ]
                  , varExpr "triple"
                  )
                , ( "testValue", [], callExpr (varExpr "withTriple") [ tuple3Expr (intExpr 1) (strExpr "a") (intExpr 2) ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `parts ( x as first, y as second ) = [ first, second ]`
with `testValue = parts ( 1, 2 )`.
-}
nestedAliasInTuple : (Src.Module -> Expectation) -> (() -> Expectation)
nestedAliasInTuple expectFn _ =
    let
        pattern =
            pTuple (pAlias (pVar "x") "first") (pAlias (pVar "y") "second")

        modul =
            makeModuleWithDefs "Test"
                [ ( "parts", [ pattern ], listExpr [ varExpr "first", varExpr "second" ] )
                , ( "testValue", [], callExpr (varExpr "parts") [ tupleExpr (intExpr 1) (intExpr 2) ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `deep (( ( a, b ), c ) as whole) = whole` with
`testValue = deep ( ( 1, "a" ), 2 )`.
-}
aliasOnNestedTuple : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnNestedTuple expectFn _ =
    let
        pattern =
            pAlias (pTuple (pTuple (pVar "a") (pVar "b")) (pVar "c")) "whole"

        modul =
            makeModuleWithDefs "Test"
                [ ( "deep", [ pattern ], varExpr "whole" )
                , ( "testValue", [], callExpr (varExpr "deep") [ tupleExpr (tupleExpr (intExpr 1) (strExpr "a")) (intExpr 2) ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- RECORD ALIAS
-- ============================================================================


{-| Returns the cases that alias a record pattern, each of two record
arguments, and a record pattern with four fields.
-}
recordAliasCases : (Src.Module -> Expectation) -> List TestCase
recordAliasCases expectFn =
    [ { label = "Alias on record pattern", run = aliasOnRecordPattern expectFn }
    , { label = "Multiple record aliases", run = multipleRecordAliases expectFn }
    , { label = "Alias on record with many fields", run = aliasOnRecordWithManyFields expectFn }
    ]


{-| Runs `expectFn` on `withRecord ({ x, y } as point) = ( point, x )` with
`testValue = withRecord { x = 1, y = "a" }`.
-}
aliasOnRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnRecordPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "withRecord"
                  , [ pAlias (pRecord [ "x", "y" ]) "point" ]
                  , tupleExpr (varExpr "point") (varExpr "x")
                  )
                , ( "testValue", [], callExpr (varExpr "withRecord") [ recordExpr [ ( "x", intExpr 1 ), ( "y", strExpr "a" ) ] ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `combine ({ a } as r1) ({ b } as r2) = ( r1, r2 )` with
`testValue = combine { a = 1 } { b = "a" }`.
-}
multipleRecordAliases : (Src.Module -> Expectation) -> (() -> Expectation)
multipleRecordAliases expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "combine"
                  , [ pAlias (pRecord [ "a" ]) "r1", pAlias (pRecord [ "b" ]) "r2" ]
                  , tupleExpr (varExpr "r1") (varExpr "r2")
                  )
                , ( "testValue", [], callExpr (varExpr "combine") [ recordExpr [ ( "a", intExpr 1 ) ], recordExpr [ ( "b", strExpr "a" ) ] ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `allFields ({ a, b, c, d } as rec) = rec`, called on a
record with exactly those four fields.
-}
aliasOnRecordWithManyFields : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnRecordWithManyFields expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "allFields"
                  , [ pAlias (pRecord [ "a", "b", "c", "d" ]) "rec" ]
                  , varExpr "rec"
                  )
                , ( "testValue", [], callExpr (varExpr "allFields") [ recordExpr [ ( "a", intExpr 1 ), ( "b", strExpr "a" ), ( "c", intExpr 2 ), ( "d", strExpr "b" ) ] ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- LIST ALIAS
-- ============================================================================


{-| Returns the cases that alias a cons pattern, a fixed-length list pattern,
the parts of a cons pattern, and a cons pattern whose tail is itself a cons
pattern.
-}
listAliasCases : (Src.Module -> Expectation) -> List TestCase
listAliasCases expectFn =
    [ { label = "Alias on cons pattern", run = aliasOnConsPattern expectFn }
    , { label = "Alias on fixed list pattern", run = aliasOnFixedListPattern expectFn }
    , { label = "Nested alias in list", run = nestedAliasInList expectFn }
    , { label = "Alias on nested cons", run = aliasOnNestedCons expectFn }
    ]


{-| Runs `expectFn` on `withList ((h :: t) as list) = ( list, h )` with
`testValue = withList [ 1, 2 ]`.
-}
aliasOnConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnConsPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "withList"
                  , [ pAlias (pCons (pVar "h") (pVar "t")) "list" ]
                  , tupleExpr (varExpr "list") (varExpr "h")
                  )
                , ( "testValue", [], callExpr (varExpr "withList") [ listExpr [ intExpr 1, intExpr 2 ] ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `pairList ([ a, b ] as both) = both` with
`testValue = pairList [ 1, 2 ]`.
-}
aliasOnFixedListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnFixedListPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "pairList"
                  , [ pAlias (pList [ pVar "a", pVar "b" ]) "both" ]
                  , varExpr "both"
                  )
                , ( "testValue", [], callExpr (varExpr "pairList") [ listExpr [ intExpr 1, intExpr 2 ] ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `parts ((h as head) :: (t as tail)) = ( head, tail )`
with `testValue = parts [ 1, 2 ]`.
-}
nestedAliasInList : (Src.Module -> Expectation) -> (() -> Expectation)
nestedAliasInList expectFn _ =
    let
        pattern =
            pCons (pAlias (pVar "h") "head") (pAlias (pVar "t") "tail")

        modul =
            makeModuleWithDefs "Test"
                [ ( "parts", [ pattern ], tupleExpr (varExpr "head") (varExpr "tail") )
                , ( "testValue", [], callExpr (varExpr "parts") [ listExpr [ intExpr 1, intExpr 2 ] ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `twoOrMore ((a :: b :: rest) as list) = list` with
`testValue = twoOrMore [ 1, 2, 3 ]`.
-}
aliasOnNestedCons : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnNestedCons expectFn _ =
    let
        pattern =
            pAlias (pCons (pVar "a") (pCons (pVar "b") (pVar "rest"))) "list"

        modul =
            makeModuleWithDefs "Test"
                [ ( "twoOrMore", [ pattern ], varExpr "list" )
                , ( "testValue", [], callExpr (varExpr "twoOrMore") [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- NESTED ALIAS
-- ============================================================================


{-| Returns the cases that alias an alias, a pair nested in a pair, and a
pair of a record pattern and an aliased cons pattern.
-}
nestedAliasCases : (Src.Module -> Expectation) -> List TestCase
nestedAliasCases expectFn =
    [ { label = "Multiple levels of alias", run = multipleLevelsOfAlias expectFn }
    , { label = "Alias in deeply nested structure", run = aliasInDeeplyNestedStructure expectFn }
    , { label = "Mixed nested aliases", run = mixedNestedAliases expectFn }
    ]


{-| Runs `expectFn` on `levels ((x as inner) as outer) = [ x, inner, outer ]`
with `testValue = levels 1`.
-}
multipleLevelsOfAlias : (Src.Module -> Expectation) -> (() -> Expectation)
multipleLevelsOfAlias expectFn _ =
    let
        pattern =
            pAlias (pAlias (pVar "x") "inner") "outer"

        modul =
            makeModuleWithDefs "Test"
                [ ( "levels", [ pattern ], listExpr [ varExpr "x", varExpr "inner", varExpr "outer" ] )
                , ( "testValue", [], callExpr (varExpr "levels") [ intExpr 1 ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `deep ( ( a, b ) as inner, c ) = ( inner, a )` with
`testValue = deep ( ( 1, "a" ), 2 )`.
-}
aliasInDeeplyNestedStructure : (Src.Module -> Expectation) -> (() -> Expectation)
aliasInDeeplyNestedStructure expectFn _ =
    let
        pattern =
            pTuple
                (pAlias (pTuple (pVar "a") (pVar "b")) "inner")
                (pVar "c")

        modul =
            makeModuleWithDefs "Test"
                [ ( "deep", [ pattern ], tupleExpr (varExpr "inner") (varExpr "a") )
                , ( "testValue", [], callExpr (varExpr "deep") [ tupleExpr (tupleExpr (intExpr 1) (strExpr "a")) (intExpr 2) ] )
                ]
    in
    expectFn modul


{-| Runs `expectFn` on `mixed (( { x }, (h :: _) as list ) as all) = all` with
`testValue = mixed ( { x = 1 }, [ 1, 2 ] )`.
-}
mixedNestedAliases : (Src.Module -> Expectation) -> (() -> Expectation)
mixedNestedAliases expectFn _ =
    let
        pattern =
            pAlias
                (pTuple
                    (pRecord [ "x" ])
                    (pAlias (pCons (pVar "h") pAnything) "list")
                )
                "all"

        modul =
            makeModuleWithDefs "Test"
                [ ( "mixed", [ pattern ], varExpr "all" )
                , ( "testValue", [], callExpr (varExpr "mixed") [ tupleExpr (recordExpr [ ( "x", intExpr 1 ) ]) (listExpr [ intExpr 1, intExpr 2 ]) ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- ALIAS IN FUNCTIONS
-- ============================================================================


{-| Returns the cases that put an alias in a let-destructuring and in the
argument of a function defined in a `let`.
-}
aliasInFunctionsCases : (Src.Module -> Expectation) -> List TestCase
aliasInFunctionsCases expectFn =
    [ { label = "Alias in let destruct", run = aliasInLetDestruct expectFn }
    , { label = "Alias used in function body", run = aliasUsedInFunctionBody expectFn }
    ]


{-| Runs `expectFn` on a `testValue` that destructures `( 1, 2 )` with
`(( a, b ) as pair)` in a `let` and returns `pair`.
-}
aliasInLetDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
aliasInLetDestruct expectFn _ =
    let
        def =
            destruct (pAlias (pTuple (pVar "a") (pVar "b")) "pair") (tupleExpr (intExpr 1) (intExpr 2))

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "pair"))
    in
    expectFn modul


{-| Runs `expectFn` on a `testValue` that defines
`process (x as original) = ( original, x )` in a `let` and returns
`process 42`.
-}
aliasUsedInFunctionBody : (Src.Module -> Expectation) -> (() -> Expectation)
aliasUsedInFunctionBody expectFn _ =
    let
        fn =
            define "process"
                [ pAlias (pVar "x") "original" ]
                (tupleExpr (varExpr "original") (varExpr "x"))

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "process") [ intExpr 42 ]))
    in
    expectFn modul



-- ============================================================================
-- ALIAS IN CASE BRANCHES
-- ============================================================================


{-| Returns the case that puts an alias in a case branch.
-}
aliasAdditionalCases : (Src.Module -> Expectation) -> List TestCase
aliasAdditionalCases expectFn =
    [ { label = "Alias with value", run = aliasWithValue expectFn }
    ]


{-| Runs `expectFn` on `testValue = case 42 of x as val -> ( x, val )`.
-}
aliasWithValue : (Src.Module -> Expectation) -> (() -> Expectation)
aliasWithValue expectFn _ =
    let
        case_ =
            caseExpr (intExpr 42)
                [ ( pAlias (pVar "x") "val", tupleExpr (varExpr "x") (varExpr "val") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul
