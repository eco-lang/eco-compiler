module Compiler.Parse.PrimitivesAndThenConsumedTest exposing (suite)

{-| Pins `Compiler.Parse.Primitives.andThen` after consumption: when the first
parser consumed input (`Cok`) and the second fails without consuming (`Eerr`),
the result is promoted to `Cerr`, so an enclosing `oneOf` does not try its next
alternative from the original position once input was consumed. This matches
upstream Elm, which passes `cerr` as the second parser's empty-error
continuation, and `loop` and `inContext` here. Before the fix the `Eerr` was
passed on as it was.
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
