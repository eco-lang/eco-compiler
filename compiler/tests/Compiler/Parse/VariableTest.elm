module Compiler.Parse.VariableTest exposing (suite)

{-| Pins `Compiler.Parse.Variable.matchingLower`, the parser for the name that
repeats a type annotation's name on the next line, which both the top-level and
the `let` definition parsers use.

  - The expected name parses, located where it was read.
  - A different name fails with the match error at the start of the name, and
    the failure is consumed: an enclosing `oneOf` does not try its next
    alternative.
  - No name (a digit, or a reserved word) fails with the repeat error at the
    start, not consumed: an enclosing `oneOf` tries its next alternative.

-}

import Compiler.Core.Annotation as A
import Compiler.Lexer.Primitives as P
import Compiler.Parse.Variable as Var
import Expect
import Test exposing (Test)


{-| `matchingLower` for `expected`, with errors rendered as text.
-}
matching : String -> P.Parser String (A.Located String)
matching expected =
    Var.matchingLower
        (\r c -> "repeat at " ++ String.fromInt r ++ ":" ++ String.fromInt c)
        (\name r c -> "match " ++ name ++ " at " ++ String.fromInt r ++ ":" ++ String.fromInt c)
        expected


{-| Runs `parser` over the whole of `src`.
-}
run : P.Parser String a -> String -> Result String a
run parser src =
    P.fromByteString parser (\r c -> "bad end at " ++ String.fromInt r ++ ":" ++ String.fromInt c) src


suite : Test
suite =
    Test.describe "Parse.Variable.matchingLower"
        [ Test.test "the expected name parses with its region" <|
            \_ ->
                run (matching "foo") "foo"
                    |> Expect.equal (Ok (A.at (A.Position 1 1) (A.Position 1 4) "foo"))
        , Test.test "a different name is a match error at its start" <|
            \_ ->
                run (matching "foo") "bar"
                    |> Expect.equal (Err "match bar at 1:1")
        , Test.test "a missing name is a repeat error" <|
            \_ ->
                run (matching "foo") "1"
                    |> Expect.equal (Err "repeat at 1:1")
        , Test.test "a different name is consumed: oneOf does not try the next alternative" <|
            \_ ->
                run (P.oneOf (\_ _ -> "none") [ matching "foo", P.pure (A.At A.zero "fallback") ]) "bar"
                    |> Expect.equal (Err "match bar at 1:1")
        , Test.test "a reserved word is not consumed: oneOf tries the next alternative" <|
            \_ ->
                run (P.oneOf (\_ _ -> "none") [ matching "foo", P.pure (A.At A.zero "fallback") ]) "if"
                    |> Expect.equal (Err "bad end at 1:1")
        ]
