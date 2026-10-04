module Compiler.Generate.MLIR.FallbackTagTest exposing (suite)

{-| Tests for `Patterns.computeFallbackTag`, which chooses the tag of a fan-out's
fallback branch. Without them, a change to the tags it returns would show up
only in the code generated for a `case`.

A _fan-out_ is a decision-tree node that tests one value. Each edge carries a
`DtTest.Test`, and a fallback branch takes every value no edge matches. When the
general fan-out lowering in `Compiler.Generate.MLIR.Expr` or `TailRec` builds an
`eco.case` for a fan-out on anything but strings, each alternative carries an
integer tag: an edge's tag is `Patterns.testToTagInt` of its test, and the
fallback's tag is `computeFallbackTag` of all the edge tests. For an `IsInt`
test the tag is the literal itself, so a tag can be as large as any integer a
program matches on.

Each fixture is a list of edge tests built directly from `DtTest` constructors.
No program is compiled.

The tests establish:

  - Four single-edge lists with fixed answers. `[IsBool True]` gives 0 and
    `[IsBool False]` gives 1, the tags `testToTagInt` gives `False` and `True`.
    `[IsNil]` gives 1, the tag `testToTagInt` gives `IsCons`. `[IsCons]` gives
    0, which is not the tag `testToTagInt` gives `IsNil` (that is
    `CtorTag.constantTag`).
  - For integer edges, the smallest non-negative integer not among the tags:
    `IsInt` 0 and 2 give 1, 0 and 1 give 2, and 2, 1 and 0, given in that
    order, give 3.
  - For large integer literals, the same rule. Four PNG chunk-type codes, each
    four ASCII letters read as a big-endian 32-bit integer and the largest of
    them 1951551059, give 0, and 0 with 1951551059 gives 1. These assert only
    the value; nothing measures how long the call takes or how much it
    allocates.

Among what is not tested: `IsCtor`, `IsChr`, `IsStr` and `IsTuple` edges;
negative or repeated tags; the two-edge lists `[IsBool True, IsBool False]` and
`[IsCons, IsNil]`; and an empty edge list.

-}

import Compiler.AST.DecisionTree.Test as DtTest
import Compiler.Generate.MLIR.Patterns as Patterns
import Expect
import Test exposing (Test, describe, test)


{-| The `computeFallbackTag` tests, in three groups: single-edge lists with fixed
answers, small sets of integer tags, and large integer literals.
-}
suite : Test
suite =
    describe "Compiler.Generate.MLIR.Patterns.computeFallbackTag"
        [ describe "two-way fast paths"
            [ test "IsBool True -> 0 (the False tag)" <|
                \_ -> Expect.equal 0 (Patterns.computeFallbackTag [ DtTest.IsBool True ])
            , test "IsBool False -> 1 (the True tag)" <|
                \_ -> Expect.equal 1 (Patterns.computeFallbackTag [ DtTest.IsBool False ])
            , test "IsCons -> 0" <|
                \_ -> Expect.equal 0 (Patterns.computeFallbackTag [ DtTest.IsCons ])
            , test "IsNil -> 1" <|
                \_ -> Expect.equal 1 (Patterns.computeFallbackTag [ DtTest.IsNil ])
            ]
        , describe "N-way: smallest non-negative unused tag"
            [ test "{0,2} -> 1" <|
                \_ -> Expect.equal 1 (Patterns.computeFallbackTag [ DtTest.IsInt 0, DtTest.IsInt 2 ])
            , test "{0,1} -> 2" <|
                \_ -> Expect.equal 2 (Patterns.computeFallbackTag [ DtTest.IsInt 0, DtTest.IsInt 1 ])
            , test "{2,1,0} (unsorted) -> 3" <|
                \_ -> Expect.equal 3 (Patterns.computeFallbackTag [ DtTest.IsInt 2, DtTest.IsInt 1, DtTest.IsInt 0 ])
            ]
        , describe "regression: large int literals must not enumerate 0..maxTag"
            [ test "PNG chunk-type codes (max 1951551059) -> 0, computed promptly" <|
                \_ ->
                    Expect.equal 0
                        (Patterns.computeFallbackTag
                            [ DtTest.IsInt 1229472850 -- IHDR
                            , DtTest.IsInt 1347179589 -- PLTE
                            , DtTest.IsInt 1951551059 -- tRNS
                            , DtTest.IsInt 1229209940 -- IDAT
                            ]
                        )
            , test "large literals with 0 used -> first gap (1)" <|
                \_ ->
                    Expect.equal 1
                        (Patterns.computeFallbackTag [ DtTest.IsInt 0, DtTest.IsInt 1951551059 ])
            ]
        ]
