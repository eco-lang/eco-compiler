module SourceIR.EdgeCaseCases exposing (expectSuite)

{-| Small programs built around parentheses, empty and unit values, expressions
nested four deep, record updates, and several kinds of pattern used together.
They are here so that a stage checked against the standard suites
(`SourceIR.Suite.StandardTestSuites`) is also given these forms.

This module asserts nothing itself. `expectSuite` takes an expectation function,
`expectFn`, and makes one elm-test test that applies it to each program in turn
through `Compiler.BulkCheck.bulkCheck`, which stops at the first failure and
reports it under that case's label. What is checked, and at which stage, is
decided by `expectFn`. Each case is a function of `expectFn` and `()` that
builds one program and returns what `expectFn` gives for it.

Every program is a Source AST module built with `Compiler.AST.SourceBuilder`,
with no type annotations, custom types or type aliases. Most are built with
`makeModule`, which makes a module named `Test` that imports `Basics` and `List`
and holds the one value `testValue`; the two that need top-level functions use
`makeModuleWithDefs`, also importing only `Basics` and `List`. All literal values
are fixed. Two programs are not exhaustive and so are not valid Elm source: the
`f :: _` argument of `complex` in "Multiple pattern types in one function", and
the `h :: t` destructuring in "All destruct patterns".

The programs, in the order they run:

  - Parentheses: `(42)`, `(1 + 2) * 3`, `(((1)))`, and a top-level
    `testFn = (\x -> x)` applied as `testFn 1`.
  - Complex expressions: two successive record updates, a record update that
    replaces a lambda-valued field, a `case` inside an `if`, an `if` inside a
    `case`, and a list of four field accessors.
  - Edge cases: the empty record, the empty list, and unit.
  - Deep nesting: lists, pairs, `let` expressions and records, each nested four
    levels deep.
  - Expression combinations: one let-bound function taking five different kinds
    of argument pattern, four let destructurings of four different pattern
    kinds, and five top-level functions with different argument patterns, one
    of which, `f1`, is called on both an integer literal and a `String`.
  - Fixed values: a pair of a record holding a list and a triple, and a pair of
    two field accesses on a let-bound record.

Among what is not tested: type annotations, custom type declarations and
constructor patterns, negation, `Float` and `Char` literals, and operators other
than `+` and `*`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , accessorExpr
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , define
        , destruct
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , pAlias
        , pAnything
        , pCons
        , pRecord
        , pTuple
        , pVar
        , parensExpr
        , recordExpr
        , strExpr
        , tuple3Expr
        , tupleExpr
        , unitExpr
        , updateExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Makes one test, named "Edge case and special expression tests " followed by
`condStr`, that passes when `expectFn` passes for every program in this module.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Edge case and special expression tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Lists every case in this module, group by group, in the order they run.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ parensCases expectFn
        , complexExpressionCases expectFn
        , edgeCaseCases expectFn
        , deepNestingCases expectFn
        , expressionCombinationCases expectFn
        , edgeCaseFixedCases expectFn
        ]



-- ============================================================================
-- PARENTHESES
-- ============================================================================


{-| Lists the cases built around parentheses: three redundant uses and one that
overrides precedence.
-}
parensCases : (Src.Module -> Expectation) -> List TestCase
parensCases expectFn =
    [ { label = "Parens around literal", run = parensAroundLiteral expectFn }
    , { label = "Parens around binop", run = parensAroundBinop expectFn }
    , { label = "Nested parens", run = nestedParens expectFn }
    , { label = "Parens around lambda", run = parensAroundLambda expectFn }
    ]


{-| Builds `testValue = (42)` for `expectFn`.
-}
parensAroundLiteral : (Src.Module -> Expectation) -> (() -> Expectation)
parensAroundLiteral expectFn _ =
    let
        modul =
            makeModule "testValue" (parensExpr (intExpr 42))
    in
    expectFn modul


{-| Builds `testValue = (1 + 2) * 3` for `expectFn`, so that the parentheses
override precedence.
-}
parensAroundBinop : (Src.Module -> Expectation) -> (() -> Expectation)
parensAroundBinop expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( parensExpr (binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2)), "*" ) ]
                    (intExpr 3)
                )
    in
    expectFn modul


{-| Builds `testValue = (((1)))` for `expectFn`.
-}
nestedParens : (Src.Module -> Expectation) -> (() -> Expectation)
nestedParens expectFn _ =
    let
        modul =
            makeModule "testValue" (parensExpr (parensExpr (parensExpr (intExpr 1))))
    in
    expectFn modul


{-| Builds a module `Test` with the top-level values `testFn = (\x -> x)` and
`testValue = testFn 1`, for `expectFn`.
-}
parensAroundLambda : (Src.Module -> Expectation) -> (() -> Expectation)
parensAroundLambda expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], parensExpr (lambdaExpr [ pVar "x" ] (varExpr "x")) )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1 ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- COMPLEX EXPRESSIONS
-- ============================================================================


{-| Lists the cases that put one kind of expression inside another.
-}
complexExpressionCases : (Src.Module -> Expectation) -> List TestCase
complexExpressionCases expectFn =
    [ { label = "Nested record updates", run = nestedRecordUpdates expectFn }
    , { label = "Lambda in record update", run = lambdaInRecordUpdate expectFn }
    , { label = "Case in if", run = caseInIf expectFn }
    , { label = "If in case", run = ifInCase expectFn }
    , { label = "Multiple accessors in list", run = multipleAccessorsInList expectFn }
    ]


{-| Builds, for `expectFn`, a `testValue` that updates a record twice in
succession: `r = { x = 1, y = 2 }`, then `r2 = { r | x = 10 }`, and the result
is `{ r2 | y = 20 }`. Despite the label, neither update is inside the other.
-}
nestedRecordUpdates : (Src.Module -> Expectation) -> (() -> Expectation)
nestedRecordUpdates expectFn _ =
    let
        record =
            recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ]

        def =
            define "r" [] record

        update1 =
            updateExpr (varExpr "r") [ ( "x", intExpr 10 ) ]

        def2 =
            define "r2" [] update1

        update2 =
            updateExpr (varExpr "r2") [ ( "y", intExpr 20 ) ]

        modul =
            makeModule "testValue" (letExpr [ def, def2 ] update2)
    in
    expectFn modul


{-| Builds, for `expectFn`, a `testValue` that binds `r = { fn = \x -> 0 }` and
returns `{ r | fn = \x -> x }`, so that the updated field holds a function.
-}
lambdaInRecordUpdate : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaInRecordUpdate expectFn _ =
    let
        record =
            recordExpr [ ( "fn", lambdaExpr [ pVar "x" ] (intExpr 0) ) ]

        def =
            define "r" [] record

        newFn =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        update =
            updateExpr (varExpr "r") [ ( "fn", newFn ) ]

        modul =
            makeModule "testValue" (letExpr [ def ] update)
    in
    expectFn modul


{-| Builds `testValue = if True then case 1 of n -> n else 0` for `expectFn`. The
`case` is the whole `then` branch and is not wrapped in a parentheses node.
-}
caseInIf : (Src.Module -> Expectation) -> (() -> Expectation)
caseInIf expectFn _ =
    let
        cond =
            boolExpr True

        thenBranch =
            caseExpr (intExpr 1)
                [ ( pVar "n", varExpr "n" )
                ]

        elseBranch =
            intExpr 0

        modul =
            makeModule "testValue" (ifExpr cond thenBranch elseBranch)
    in
    expectFn modul


{-| Builds `testValue = case 1 of n -> if True then n else 0` for `expectFn`.
-}
ifInCase : (Src.Module -> Expectation) -> (() -> Expectation)
ifInCase expectFn _ =
    let
        case_ =
            caseExpr (intExpr 1)
                [ ( pVar "n"
                  , ifExpr (boolExpr True) (varExpr "n") (intExpr 0)
                  )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


{-| Builds `testValue = [ .a, .b, .c, .d ]` for `expectFn`: a list whose four
elements are field accessor functions for different fields.
-}
multipleAccessorsInList : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAccessorsInList expectFn _ =
    let
        modul =
            makeModule "testValue"
                (listExpr
                    [ accessorExpr "a"
                    , accessorExpr "b"
                    , accessorExpr "c"
                    , accessorExpr "d"
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- EDGE CASES
-- ============================================================================


{-| Lists the cases whose whole value is an empty or unit literal.
-}
edgeCaseCases : (Src.Module -> Expectation) -> List TestCase
edgeCaseCases expectFn =
    [ { label = "Empty record", run = emptyRecord expectFn }
    , { label = "Empty list", run = emptyListExpr expectFn }
    , { label = "Unit expression", run = unitExpression expectFn }
    ]


{-| Builds `testValue = {}` for `expectFn`.
-}
emptyRecord : (Src.Module -> Expectation) -> (() -> Expectation)
emptyRecord expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [])
    in
    expectFn modul


{-| Builds `testValue = []` for `expectFn`.
-}
emptyListExpr : (Src.Module -> Expectation) -> (() -> Expectation)
emptyListExpr expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [])
    in
    expectFn modul


{-| Builds `testValue = ()` for `expectFn`.
-}
unitExpression : (Src.Module -> Expectation) -> (() -> Expectation)
unitExpression expectFn _ =
    let
        modul =
            makeModule "testValue" unitExpr
    in
    expectFn modul



-- ============================================================================
-- DEEP NESTING
-- ============================================================================


{-| Lists the cases that nest one construct four levels deep.
-}
deepNestingCases : (Src.Module -> Expectation) -> List TestCase
deepNestingCases expectFn =
    [ { label = "Deeply nested lists", run = deeplyNestedLists expectFn }
    , { label = "Deeply nested tuples", run = deeplyNestedTuples expectFn }
    , { label = "Deeply nested lets", run = deeplyNestedLets expectFn }
    , { label = "Deeply nested records", run = deeplyNestedRecords expectFn }
    ]


{-| Builds `testValue = [ [ [ [ 1 ] ] ] ]` for `expectFn`.
-}
deeplyNestedLists : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedLists expectFn _ =
    let
        level4 =
            listExpr [ intExpr 1 ]

        level3 =
            listExpr [ level4 ]

        level2 =
            listExpr [ level3 ]

        level1 =
            listExpr [ level2 ]

        modul =
            makeModule "testValue" level1
    in
    expectFn modul


{-| Builds `testValue = ((((1, 2), 3), 4), 5)` for `expectFn`.
-}
deeplyNestedTuples : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedTuples expectFn _ =
    let
        level4 =
            tupleExpr (intExpr 1) (intExpr 2)

        level3 =
            tupleExpr level4 (intExpr 3)

        level2 =
            tupleExpr level3 (intExpr 4)

        level1 =
            tupleExpr level2 (intExpr 5)

        modul =
            makeModule "testValue" level1
    in
    expectFn modul


{-| Builds, for `expectFn`, a `testValue` of four nested `let` expressions, each
binding one of `a` to `d` to the numbers 1 to 4. Only `d` is used, as the
innermost body.
-}
deeplyNestedLets : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedLets expectFn _ =
    let
        inner3 =
            letExpr [ define "d" [] (intExpr 4) ] (varExpr "d")

        inner2 =
            letExpr [ define "c" [] (intExpr 3) ] inner3

        inner1 =
            letExpr [ define "b" [] (intExpr 2) ] inner2

        modul =
            makeModule "testValue" (letExpr [ define "a" [] (intExpr 1) ] inner1)
    in
    expectFn modul


{-| Builds `testValue = { nested = { nested = { nested = { value = 1 } } } }` for
`expectFn`.
-}
deeplyNestedRecords : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedRecords expectFn _ =
    let
        level4 =
            recordExpr [ ( "value", intExpr 1 ) ]

        level3 =
            recordExpr [ ( "nested", level4 ) ]

        level2 =
            recordExpr [ ( "nested", level3 ) ]

        level1 =
            recordExpr [ ( "nested", level2 ) ]

        modul =
            makeModule "testValue" level1
    in
    expectFn modul



-- ============================================================================
-- EXPRESSION COMBINATIONS
-- ============================================================================


{-| Lists the cases that use several kinds of pattern in one program.
-}
expressionCombinationCases : (Src.Module -> Expectation) -> List TestCase
expressionCombinationCases expectFn =
    [ { label = "Multiple pattern types in one function", run = multiplePatternTypesInOneFunction expectFn }
    , { label = "All destruct patterns", run = allDestructPatterns expectFn }
    , { label = "Multiple definitions with various patterns", run = multipleDefinitionsWithVariousPatterns expectFn }
    ]


{-| Builds, for `expectFn`, a `testValue` that defines in a `let` the function
`complex a (b, c) { d, e } (f :: _) (g as h) = [ a, b, d, f, g ]` and returns
it unapplied. The `f :: _` argument pattern does not match an empty list.
-}
multiplePatternTypesInOneFunction : (Src.Module -> Expectation) -> (() -> Expectation)
multiplePatternTypesInOneFunction expectFn _ =
    let
        fn =
            define "complex"
                [ pVar "a"
                , pTuple (pVar "b") (pVar "c")
                , pRecord [ "d", "e" ]
                , pCons (pVar "f") pAnything
                , pAlias (pVar "g") "h"
                ]
                (listExpr [ varExpr "a", varExpr "b", varExpr "d", varExpr "f", varExpr "g" ])

        modul =
            makeModule "testValue" (letExpr [ fn ] (varExpr "complex"))
    in
    expectFn modul


{-| Builds, for `expectFn`, a `testValue` whose `let` destructures with four
kinds of pattern: `(a, b) = (1, 2)`, `{ x } = { x = 3 }`, `h :: t = [ 4, 5 ]`
and `v as w = 6`, and whose body is `[ a, x, h, v ]`. These are not every kind
of pattern, and `h :: t` does not match an empty list.
-}
allDestructPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
allDestructPatterns expectFn _ =
    let
        def1 =
            destruct (pTuple (pVar "a") (pVar "b")) (tupleExpr (intExpr 1) (intExpr 2))

        def2 =
            destruct (pRecord [ "x" ]) (recordExpr [ ( "x", intExpr 3 ) ])

        def3 =
            destruct (pCons (pVar "h") (pVar "t")) (listExpr [ intExpr 4, intExpr 5 ])

        def4 =
            destruct (pAlias (pVar "v") "w") (intExpr 6)

        modul =
            makeModule "testValue"
                (letExpr [ def1, def2, def3, def4 ]
                    (listExpr [ varExpr "a", varExpr "x", varExpr "h", varExpr "v" ])
                )
    in
    expectFn modul


{-| Builds, for `expectFn`, a module `Test` with five top-level functions taking
different argument patterns (`f1 x`, `f2 (a, b)`, `f3 { name }`, `f4 _` and
the three-argument `f5 a b c`) and a `testValue` that is a nested tuple calling
each of them. `f1` is called on both `1` and `"hi"`, and `f5` on `10`,
`"mid"` and `30`.
-}
multipleDefinitionsWithVariousPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefinitionsWithVariousPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "f1", [ pVar "x" ], varExpr "x" )
                , ( "f2", [ pTuple (pVar "a") (pVar "b") ], varExpr "a" )
                , ( "f3", [ pRecord [ "name" ] ], varExpr "name" )
                , ( "f4", [ pAnything ], intExpr 0 )
                , ( "f5", [ pVar "a", pVar "b", pVar "c" ], varExpr "b" )
                , ( "testValue"
                  , []
                  , tupleExpr
                        (tupleExpr
                            (callExpr (varExpr "f1") [ intExpr 1 ])
                            (callExpr (varExpr "f1") [ strExpr "hi" ])
                        )
                        (tupleExpr
                            (tupleExpr
                                (callExpr (varExpr "f2") [ tupleExpr (intExpr 2) (intExpr 3) ])
                                (callExpr (varExpr "f3") [ recordExpr [ ( "name", strExpr "hello" ) ] ])
                            )
                            (tupleExpr
                                (callExpr (varExpr "f4") [ intExpr 99 ])
                                (callExpr (varExpr "f5") [ intExpr 10, strExpr "mid", intExpr 30 ])
                            )
                        )
                  )
                ]
    in
    expectFn modul



-- ============================================================================
-- FIXED VALUES
-- ============================================================================


{-| Lists the cases that combine containers holding fixed literal values.
-}
edgeCaseFixedCases : (Src.Module -> Expectation) -> List TestCase
edgeCaseFixedCases expectFn =
    [ { label = "Complex expression with fixed values", run = complexExpressionWithFixedValues expectFn }
    , { label = "Mixed types with fixed values", run = mixedTypesWithFixedValues expectFn }
    ]


{-| Builds `testValue = ({ values = [ 1, 2, 3 ] }, (1, 2, 3))` for `expectFn`.
-}
complexExpressionWithFixedValues : (Src.Module -> Expectation) -> (() -> Expectation)
complexExpressionWithFixedValues expectFn _ =
    let
        a =
            1

        b =
            2

        c =
            3

        list =
            listExpr [ intExpr a, intExpr b, intExpr c ]

        record =
            recordExpr [ ( "values", list ) ]

        tuple =
            tuple3Expr (intExpr a) (intExpr b) (intExpr c)

        modul =
            makeModule "testValue" (tupleExpr record tuple)
    in
    expectFn modul


{-| Builds, for `expectFn`, a `testValue` that binds
`r = { name = "hello", count = 42 }` and returns `(r.name, r.count)`, a pair of
a `String` and a number.
-}
mixedTypesWithFixedValues : (Src.Module -> Expectation) -> (() -> Expectation)
mixedTypesWithFixedValues expectFn _ =
    let
        s =
            "hello"

        n =
            42

        record =
            recordExpr
                [ ( "name", strExpr s )
                , ( "count", intExpr n )
                ]

        def =
            define "r" [] record

        result =
            tupleExpr
                (accessExpr (varExpr "r") "name")
                (accessExpr (varExpr "r") "count")

        modul =
            makeModule "testValue" (letExpr [ def ] result)
    in
    expectFn modul
