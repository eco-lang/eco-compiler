module SourceIR.PatternComplexityFuzzCases exposing (expectSuite)

{-| A `case` is compiled into a decision tree: a tree of tests on parts of the
subject, ending in the branch to take. When patterns nest, alias or overlap,
building that tree means choosing which part of the subject to test first and
binding each branch's variables to the right parts of it. These tests build
`case` expressions whose patterns nest, alias and overlap.

`expectSuite` returns six fuzz tests in three groups. Each test builds a module
with `Compiler.AST.SourceBuilder.makeModule`, whose one top-level value,
`testValue`, is a `case` expression, and passes it to the expectation function
it is given. That function decides what is checked; this module asserts
nothing itself.

The branch patterns of each test are fixed. In five tests the fuzzer varies
only the integer literals in the subject, so every run builds the same patterns;
in the overlapping-integer test the subject is a random `Int` expression from
`SourceIR.Fuzz.TypedExpr.intExprFuzzer`, with a depth budget of 1, so it may
itself be a `let`, an `if`, a negation or a one-branch `case`.

Below, programs are sketched as Elm source, with `v1`, `v2` and `v3` for the
random literals, and branches listed in order. Not every program is one Elm
would accept. Several have a branch after others that already match everything,
which the pattern-match checker in `Compiler.Nitpick.PatternMatches` reports as
redundant. `Fuzz.int` can give negative literals, which the parser builds as a
negation instead, and one pattern is a negative `Int`, which the parser never
builds.

  - "Nested tuple patterns": subject `((v1, v2), (v1, v2))`, branches
    `((a, b), (c, d))`, `((0, x), (y, _))` and `_`.
  - "Nested list patterns": subject `[[v1], [v2]]`, branches
    `(h :: t) :: rest`, `[x] :: ys`, `[]` and `_`.
  - "Mixed nested patterns": subject `([v1, v2], (v2, v3))`, branches
    `(x :: xs, (a, b))`, `([], (_, _))`, `([y], t)` and `_`.
  - "As-patterns with nested inner": subject `(v1, v2)`, branches
    `(a, b) as pair`, `(0, x) as zeroPair` and `_ as whole`, each returning
    its alias.
  - "Overlapping int patterns": a random `Int` subject, branches `0`, `1`,
    `2`, `-1` and `n`.
  - "Overlapping tuple patterns": subject `(v1, v2)`, branches `(0, _)`,
    `(_, 0)`, `(1, 1)` and `(x, y)`.

Among what is not tested: record, constructor, string and character patterns;
patterns in function arguments or `let` definitions.

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


{-| Builds the six pattern-complexity tests, each checking its generated module
with `expectFn`. `condStr` is appended to the name of every group and test.
-}
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


{-| Builds the group of three tests whose patterns nest tuples in tuples, lists
in lists, and a list and a tuple in a tuple, each checking its module with
`expectFn`.
-}
nestedPatternTests : (Src.Module -> Expectation) -> String -> Test
nestedPatternTests expectFn condStr =
    Test.describe ("Nested patterns " ++ condStr)
        [ Test.fuzz nestedTuplePatternCaseFuzzer
            ("Nested tuple patterns " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz nestedListPatternCaseFuzzer
            ("Nested list patterns " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz mixedNestedPatternCaseFuzzer
            ("Mixed nested patterns " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


{-| Produces a fuzzer for a `case` of `((v1, v2), (v1, v2))`, with `v1` and
`v2` random integer literals, whose branches are `((a, b), (c, d))`,
`((0, x), (y, _))` and `_`, returning 1, 2 and 0. The scope is ignored.

The first pattern matches every subject, so the other two branches are
redundant.

-}
nestedTuplePatternCaseFuzzer : Fuzzer Src.Expr
nestedTuplePatternCaseFuzzer =
    Fuzz.map2
        (\val1 val2 ->
            let
                subject =
                    B.tupleExpr
                        (B.tupleExpr (B.intExpr val1) (B.intExpr val2))
                        (B.tupleExpr (B.intExpr val1) (B.intExpr val2))

                branch1 =
                    ( B.pTuple
                        (B.pTuple (B.pVar "a") (B.pVar "b"))
                        (B.pTuple (B.pVar "c") (B.pVar "d"))
                    , B.intExpr 1
                    )

                branch2 =
                    ( B.pTuple
                        (B.pTuple (B.pInt 0) (B.pVar "x"))
                        (B.pTuple (B.pVar "y") B.pAnything)
                    , B.intExpr 2
                    )

                catchAll =
                    ( B.pAnything, B.intExpr 0 )
            in
            B.caseExpr subject [ branch1, branch2, catchAll ]
        )
        Fuzz.int
        Fuzz.int


{-| Produces a fuzzer for a `case` of `[[v1], [v2]]`, with `v1` and `v2`
random integer literals, whose branches are `(h :: t) :: rest`, `[x] :: ys`,
`[]` and `_`, returning 1, 2, 3 and 0. The scope is ignored.

The second pattern matches only lists the first already matches, so its branch
is redundant.

-}
nestedListPatternCaseFuzzer : Fuzzer Src.Expr
nestedListPatternCaseFuzzer =
    Fuzz.map2
        (\val1 val2 ->
            let
                subject =
                    B.listExpr
                        [ B.listExpr [ B.intExpr val1 ]
                        , B.listExpr [ B.intExpr val2 ]
                        ]

                branch1 =
                    ( B.pCons
                        (B.pCons (B.pVar "h") (B.pVar "t"))
                        (B.pVar "rest")
                    , B.intExpr 1
                    )

                branch2 =
                    ( B.pCons
                        (B.pList [ B.pVar "x" ])
                        (B.pVar "ys")
                    , B.intExpr 2
                    )

                branch3 =
                    ( B.pList [], B.intExpr 3 )

                catchAll =
                    ( B.pAnything, B.intExpr 0 )
            in
            B.caseExpr subject [ branch1, branch2, branch3, catchAll ]
        )
        Fuzz.int
        Fuzz.int


{-| Produces a fuzzer for a `case` of `([v1, v2], (v2, v3))`, with `v1`, `v2`
and `v3` random integer literals, whose branches are `(x :: xs, (a, b))`,
`([], (_, _))`, `([y], t)` and `_`, returning 1, 2, 3 and 0. The scope is
ignored.

The first two patterns between them match every subject, so the last two
branches are redundant.

-}
mixedNestedPatternCaseFuzzer : Fuzzer Src.Expr
mixedNestedPatternCaseFuzzer =
    Fuzz.map3
        (\val1 val2 val3 ->
            let
                subject =
                    B.tupleExpr
                        (B.listExpr [ B.intExpr val1, B.intExpr val2 ])
                        (B.tupleExpr (B.intExpr val2) (B.intExpr val3))

                branch1 =
                    ( B.pTuple
                        (B.pCons (B.pVar "x") (B.pVar "xs"))
                        (B.pTuple (B.pVar "a") (B.pVar "b"))
                    , B.intExpr 1
                    )

                branch2 =
                    ( B.pTuple
                        (B.pList [])
                        (B.pTuple B.pAnything B.pAnything)
                    , B.intExpr 2
                    )

                branch3 =
                    ( B.pTuple
                        (B.pList [ B.pVar "y" ])
                        (B.pVar "t")
                    , B.intExpr 3
                    )

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


{-| Builds the group holding the one as-pattern test, which checks its module
with `expectFn`.
-}
asPatternTests : (Src.Module -> Expectation) -> String -> Test
asPatternTests expectFn condStr =
    Test.describe ("As-patterns " ++ condStr)
        [ Test.fuzz asPatternCaseFuzzer
            ("As-patterns with nested inner " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


{-| Produces a fuzzer for a `case` of `(v1, v2)`, with `v1` and `v2` random
integer literals, whose branches are `(a, b) as pair`, `(0, x) as zeroPair` and
`_ as whole`, each returning the value its alias names. The scope is ignored.

The first pattern matches every subject, so the other two branches are
redundant.

-}
asPatternCaseFuzzer : Fuzzer Src.Expr
asPatternCaseFuzzer =
    Fuzz.map2
        (\val1 val2 ->
            let
                subject =
                    B.tupleExpr (B.intExpr val1) (B.intExpr val2)

                branch1 =
                    ( B.pAlias
                        (B.pTuple (B.pVar "a") (B.pVar "b"))
                        "pair"
                    , B.varExpr "pair"
                    )

                branch2 =
                    ( B.pAlias
                        (B.pTuple (B.pInt 0) (B.pVar "x"))
                        "zeroPair"
                    , B.varExpr "zeroPair"
                    )

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


{-| Builds the group of two tests whose patterns overlap, so that some subjects
match more than one branch, each checking its module with `expectFn`.
-}
overlappingPatternTests : (Src.Module -> Expectation) -> String -> Test
overlappingPatternTests expectFn condStr =
    Test.describe ("Overlapping patterns " ++ condStr)
        [ Test.fuzz (overlappingIntPatternCaseFuzzer (emptyScope 2))
            ("Overlapping int patterns " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz overlappingTuplePatternCaseFuzzer
            ("Overlapping tuple patterns " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


{-| Produces a fuzzer for a `case` of a random `Int` expression, generated by
`SourceIR.Fuzz.TypedExpr.intExprFuzzer` with the depth budget of `scope` one
less, whose branches are `0`, `1`, `2`, `-1` and `n`, returning 100, 101, 102,
99 and `n`.

The `-1` pattern is a negative `Int` pattern, which the parser never builds.

-}
overlappingIntPatternCaseFuzzer : Scope -> Fuzzer Src.Expr
overlappingIntPatternCaseFuzzer scope =
    TE.intExprFuzzer (decrementDepth scope)
        |> Fuzz.map
            (\subject ->
                let
                    branch1 =
                        ( B.pInt 0, B.intExpr 100 )

                    branch2 =
                        ( B.pInt 1, B.intExpr 101 )

                    branch3 =
                        ( B.pInt 2, B.intExpr 102 )

                    branch4 =
                        ( B.pInt -1, B.intExpr 99 )

                    catchAll =
                        ( B.pVar "n", B.varExpr "n" )
                in
                B.caseExpr subject [ branch1, branch2, branch3, branch4, catchAll ]
            )


{-| Produces a fuzzer for a `case` of `(v1, v2)`, with `v1` and `v2` random
`Int` literals, whose branches are `(0, _)`, `(_, 0)`, `(1, 1)` and `(x, y)`,
returning 1, 2, 3 and `x + y`. The scope is ignored.

The first two patterns both match `(0, 0)`, and the last matches every subject.

-}
overlappingTuplePatternCaseFuzzer : Fuzzer Src.Expr
overlappingTuplePatternCaseFuzzer =
    Fuzz.map2
        (\val1 val2 ->
            let
                subject =
                    B.tupleExpr (B.intExpr val1) (B.intExpr val2)

                branch1 =
                    ( B.pTuple (B.pInt 0) B.pAnything, B.intExpr 1 )

                branch2 =
                    ( B.pTuple B.pAnything (B.pInt 0), B.intExpr 2 )

                branch3 =
                    ( B.pTuple (B.pInt 1) (B.pInt 1), B.intExpr 3 )

                branch4 =
                    ( B.pTuple (B.pVar "x") (B.pVar "y")
                    , B.binopsExpr [ ( B.varExpr "x", "+" ) ] (B.varExpr "y")
                    )
            in
            B.caseExpr subject [ branch1, branch2, branch3, branch4 ]
        )
        Fuzz.int
        Fuzz.int
