module Compiler.Parse.PrimitivesAndThenConsumedTest exposing (suite)

{-| Reproduces a bug in `Compiler.Parse.Primitives.andThen`: when the first
parser consumed input (`Cok`) and the second fails without consuming (`Eerr`),
the result is passed on as `Eerr` instead of being promoted to `Cerr`. An
enclosing `oneOf` then tries its next alternative from the original position
even though input was consumed (upstream Elm passes `cerr` as the second
parser's empty-error continuation; `loop` and `inContext` here promote too).

EXPECTED TO FAIL until the bug is fixed.

-}

import Compiler.Parse.Primitives as P
import Expect
import Test exposing (Test)


ab : P.Parser String ()
ab =
    P.word1 'a' (\_ _ -> "want a")
        |> P.andThen (\_ -> P.word1 'b' (\_ _ -> "want b"))


ac : P.Parser String ()
ac =
    P.word1 'a' (\_ _ -> "want a")
        |> P.andThen (\_ -> P.word1 'c' (\_ _ -> "want c"))


isConsumedError : P.PStep x a -> Bool
isConsumedError step =
    case step of
        P.Cerr _ _ _ ->
            True

        _ ->
            False


suite : Test
suite =
    Test.describe "Primitives.andThen after consumption"
        [ Test.test "Cok then Eerr is a consumed error" <|
            \_ ->
                let
                    (P.Parser run) =
                        ab
                in
                run (P.State { src = "ac", pos = 0, end = 2, indent = 0, row = 1, col = 1 })
                    |> isConsumedError
                    |> Expect.equal True
        , Test.test "oneOf does not try the next alternative once input was consumed" <|
            \_ ->
                P.fromByteString (P.oneOf (\_ _ -> "none") [ ab, ac ]) (\_ _ -> "bad end") "ac"
                    |> Expect.equal (Err "want b")
        ]
