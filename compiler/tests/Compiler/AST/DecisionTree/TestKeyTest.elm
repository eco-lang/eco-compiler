module Compiler.AST.DecisionTree.TestKeyTest exposing (suite)

{-| Tests for `Compiler.AST.DecisionTree.Test.testToComparable` on `Char` and
`String` literal tests, which are keyed by the value the literal denotes, not
by its escaped text. Keyed by text, `'a'` and `'\u{0061}'` became two tests and
the generated `eco.case` carried the tag 97 twice
(test/elm/src/CaseCharEscapedDuplicateTest.elm).
-}

import Compiler.AST.DecisionTree.Test as DT
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Compiler.AST.DecisionTree.Test.testToComparable"
        [ Test.test "'a' and '\\u0061' share a key" <|
            \_ ->
                DT.testToComparable (DT.IsChr "\\u0061")
                    |> Expect.equal (DT.testToComparable (DT.IsChr "a"))
        , Test.test "\"hi\" and \"\\u0068i\" share a key" <|
            \_ ->
                DT.testToComparable (DT.IsStr "\\u0068i")
                    |> Expect.equal (DT.testToComparable (DT.IsStr "hi"))
        , Test.test "'a' and 'b' differ" <|
            \_ ->
                (DT.testToComparable (DT.IsChr "a") == DT.testToComparable (DT.IsChr "b"))
                    |> Expect.equal False
        , Test.test "a Char and a String of one character differ" <|
            \_ ->
                (DT.testToComparable (DT.IsChr "a") == DT.testToComparable (DT.IsStr "a"))
                    |> Expect.equal False
        ]
