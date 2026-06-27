module Compiler.Generate.MLIR.FallbackTagTest exposing (suite)

{-| Unit tests for `Patterns.computeFallbackTag`.

The fallback tag is the smallest non-negative integer not used by a fan-out's
edge tests. These tests pin that behaviour for the small constructor / 2-way
cases and guard against the O(maxTag) allocation regression: for `int` cases
`testToTagInt` returns the literal value, so a case over large literals (e.g.
PNG chunk-type codes ~1.95e9 in justgook/elm-image) must still return promptly
rather than enumerating `0..maxTag`.

-}

import Compiler.AST.DecisionTree.Test as DtTest
import Compiler.Generate.MLIR.Patterns as Patterns
import Expect
import Test exposing (Test, describe, test)


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
