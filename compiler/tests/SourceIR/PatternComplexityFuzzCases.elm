module SourceIR.PatternComplexityFuzzCases exposing (expectSuite)

{-| Fuzz tests for pattern complexity.

These tests stress the pattern matching decision tree compiler by generating:

1.  Deeply nested patterns (tuples inside tuples, lists inside records, etc.)
2.  As-patterns with complex inner patterns
3.  Multiple overlapping patterns in case expressions

The goal is to find edge cases in the decision tree construction
that simpler deterministic tests might miss.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as B exposing (makeModule)
import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer)
import SourceIR.Fuzz.TypedExpr as TE
    exposing
        ( Scope
        , decrementDepth
        , emptyScope
        )
import Test exposing (Test)



-- =============================================================================
-- TEST SUITE
-- =============================================================================


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Pattern complexity fuzz tests " ++ condStr)
        [ nestedPatternTests expectFn condStr
        , asPatternTests expectFn condStr
        , overlappingPatternTests expectFn condStr
        ]



-- =============================================================================
-- NESTED PATTERN TESTS
-- =============================================================================


nestedPatternTests : (Src.Module -> Expectation) -> String -> Test
nestedPatternTests expectFn condStr =
    Test.describe ("Nested patterns " ++ condStr)
        [ Test.fuzz (nestedTuplePatternCaseFuzzer (emptyScope 2))
            ("Nested tuple patterns " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (nestedListPatternCaseFuzzer (emptyScope 2))
            ("Nested list patterns " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (mixedNestedPatternCaseFuzzer (emptyScope 2))
            ("Mixed nested patterns " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


{-| Generate a case expression with nested tuple patterns.
Patterns like: ((a, b), (c, d)) or ((1, x), (y, 2))
-}
nestedTuplePatternCaseFuzzer : Scope -> Fuzzer Src.Expr
nestedTuplePatternCaseFuzzer _ =
    Fuzz.map2
        (\val1 val2 ->
            let
                subject =
                    B.tupleExpr
                        (B.tupleExpr (B.intExpr val1) (B.intExpr val2))
                        (B.tupleExpr (B.intExpr val1) (B.intExpr val2))

                -- Branch 1: ((a, b), (c, d)) - all variables
                branch1 =
                    ( B.pTuple
                        (B.pTuple (B.pVar "a") (B.pVar "b"))
                        (B.pTuple (B.pVar "c") (B.pVar "d"))
                    , B.intExpr 1
                    )

                -- Branch 2: ((0, x), (y, _)) - mix of literal, vars, wildcard
                branch2 =
                    ( B.pTuple
                        (B.pTuple (B.pInt 0) (B.pVar "x"))
                        (B.pTuple (B.pVar "y") B.pAnything)
                    , B.intExpr 2
                    )

                -- Catch-all
                catchAll =
                    ( B.pAnything, B.intExpr 0 )
            in
            B.caseExpr subject [ branch1, branch2, catchAll ]
        )
        Fuzz.int
        Fuzz.int


{-| Generate a case expression with nested list patterns.
Patterns like: (x :: xs) :: rest or [[a], [b, c]]
-}
nestedListPatternCaseFuzzer : Scope -> Fuzzer Src.Expr
nestedListPatternCaseFuzzer _ =
    Fuzz.map2
        (\val1 val2 ->
            let
                subject =
                    B.listExpr
                        [ B.listExpr [ B.intExpr val1 ]
                        , B.listExpr [ B.intExpr val2 ]
                        ]

                -- Branch 1: (h :: t) :: rest - cons inside cons
                branch1 =
                    ( B.pCons
                        (B.pCons (B.pVar "h") (B.pVar "t"))
                        (B.pVar "rest")
                    , B.intExpr 1
                    )

                -- Branch 2: [[x], ys] - list pattern inside list
                branch2 =
                    ( B.pCons
                        (B.pList [ B.pVar "x" ])
                        (B.pVar "ys")
                    , B.intExpr 2
                    )

                -- Branch 3: [] - empty list
                branch3 =
                    ( B.pList [], B.intExpr 3 )

                -- Catch-all
                catchAll =
                    ( B.pAnything, B.intExpr 0 )
            in
            B.caseExpr subject [ branch1, branch2, branch3, catchAll ]
        )
        Fuzz.int
        Fuzz.int


{-| Generate a case expression with mixed nested patterns.
Combines tuples and lists in patterns.
-}
mixedNestedPatternCaseFuzzer : Scope -> Fuzzer Src.Expr
mixedNestedPatternCaseFuzzer _ =
    Fuzz.map3
        (\val1 val2 val3 ->
            let
                subject =
                    B.tupleExpr
                        (B.listExpr [ B.intExpr val1, B.intExpr val2 ])
                        (B.tupleExpr (B.intExpr val2) (B.intExpr val3))

                -- Branch 1: (x :: xs, (a, b))
                branch1 =
                    ( B.pTuple
                        (B.pCons (B.pVar "x") (B.pVar "xs"))
                        (B.pTuple (B.pVar "a") (B.pVar "b"))
                    , B.intExpr 1
                    )

                -- Branch 2: ([], (_, _))
                branch2 =
                    ( B.pTuple
                        (B.pList [])
                        (B.pTuple B.pAnything B.pAnything)
                    , B.intExpr 2
                    )

                -- Branch 3: ([y], t)
                branch3 =
                    ( B.pTuple
                        (B.pList [ B.pVar "y" ])
                        (B.pVar "t")
                    , B.intExpr 3
                    )

                -- Catch-all
                catchAll =
                    ( B.pAnything, B.intExpr 0 )
            in
            B.caseExpr subject [ branch1, branch2, branch3, catchAll ]
        )
        Fuzz.int
        Fuzz.int
        Fuzz.int



-- =============================================================================
-- AS-PATTERN TESTS
-- =============================================================================


asPatternTests : (Src.Module -> Expectation) -> String -> Test
asPatternTests expectFn condStr =
    Test.describe ("As-patterns " ++ condStr)
        [ Test.fuzz (asPatternCaseFuzzer (emptyScope 2))
            ("As-patterns with nested inner " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


{-| Generate case expressions with as-patterns.
Patterns like: ((a, b) as pair) or (x :: xs as whole)
-}
asPatternCaseFuzzer : Scope -> Fuzzer Src.Expr
asPatternCaseFuzzer _ =
    Fuzz.map2
        (\val1 val2 ->
            let
                subject =
                    B.tupleExpr (B.intExpr val1) (B.intExpr val2)

                -- Branch 1: (a, b) as pair
                branch1 =
                    ( B.pAlias
                        (B.pTuple (B.pVar "a") (B.pVar "b"))
                        "pair"
                    , B.varExpr "pair"
                    )

                -- Branch 2: (0, x) as zeroPair - with literal
                branch2 =
                    ( B.pAlias
                        (B.pTuple (B.pInt 0) (B.pVar "x"))
                        "zeroPair"
                    , B.varExpr "zeroPair"
                    )

                -- Catch-all with as-pattern: _ as whole
                catchAll =
                    ( B.pAlias B.pAnything "whole"
                    , B.varExpr "whole"
                    )
            in
            B.caseExpr subject [ branch1, branch2, catchAll ]
        )
        Fuzz.int
        Fuzz.int



-- =============================================================================
-- OVERLAPPING PATTERN TESTS
-- =============================================================================


overlappingPatternTests : (Src.Module -> Expectation) -> String -> Test
overlappingPatternTests expectFn condStr =
    Test.describe ("Overlapping patterns " ++ condStr)
        [ Test.fuzz (overlappingIntPatternCaseFuzzer (emptyScope 2))
            ("Overlapping int patterns " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (overlappingTuplePatternCaseFuzzer (emptyScope 2))
            ("Overlapping tuple patterns " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


{-| Generate case expressions with overlapping integer patterns.
Tests decision tree construction with multiple specific values.
-}
overlappingIntPatternCaseFuzzer : Scope -> Fuzzer Src.Expr
overlappingIntPatternCaseFuzzer scope =
    TE.intExprFuzzer (decrementDepth scope)
        |> Fuzz.map
            (\subject ->
                let
                    -- Multiple specific int patterns
                    branch1 =
                        ( B.pInt 0, B.intExpr 100 )

                    branch2 =
                        ( B.pInt 1, B.intExpr 101 )

                    branch3 =
                        ( B.pInt 2, B.intExpr 102 )

                    branch4 =
                        ( B.pInt -1, B.intExpr 99 )

                    -- Catch-all
                    catchAll =
                        ( B.pVar "n", B.varExpr "n" )
                in
                B.caseExpr subject [ branch1, branch2, branch3, branch4, catchAll ]
            )


{-| Generate case expressions with overlapping tuple patterns.
Different patterns match different components of the tuple.
-}
overlappingTuplePatternCaseFuzzer : Scope -> Fuzzer Src.Expr
overlappingTuplePatternCaseFuzzer _ =
    Fuzz.map2
        (\val1 val2 ->
            let
                subject =
                    B.tupleExpr (B.intExpr val1) (B.intExpr val2)

                -- Match first component only
                branch1 =
                    ( B.pTuple (B.pInt 0) B.pAnything, B.intExpr 1 )

                -- Match second component only
                branch2 =
                    ( B.pTuple B.pAnything (B.pInt 0), B.intExpr 2 )

                -- Match both components
                branch3 =
                    ( B.pTuple (B.pInt 1) (B.pInt 1), B.intExpr 3 )

                -- Match with different variables
                branch4 =
                    ( B.pTuple (B.pVar "x") (B.pVar "y")
                    , B.binopsExpr [ ( B.varExpr "x", "+" ) ] (B.varExpr "y")
                    )
            in
            B.caseExpr subject [ branch1, branch2, branch3, branch4 ]
        )
        Fuzz.int
        Fuzz.int
