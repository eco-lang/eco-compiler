module ParseLengthSweepRegressionDTest exposing (main)

{-| A small hand-written parser that reads a double-quoted string one `Char` at a
time with `String.uncons` returns the text between the quotes, for inputs of
several lengths.

Each input is built at run time as a quote, `n` copies of `a` and a quote, for
`n` = 0 to 8, 12 and 16. The parser accumulates the characters with `++` until
it reaches the closing quote, so every case is expected to print `Just`
followed by its `n` letters; the empty body prints `Just` alone.

## eco

Regression probe D for the stage-7 bootstrap failure described in test/eco-elm-core/src/HeapStringFieldRegressionATest.elm. It sweeps the input length to see which lengths fail, on the hypothesis that the failures clustered at small lengths falling into one allocator size bucket.

-}

-- CHECK: d_n0: "Just"
-- CHECK: d_n1: "Just a"
-- CHECK: d_n2: "Just aa"
-- CHECK: d_n3: "Just aaa"
-- CHECK: d_n4: "Just aaaa"
-- CHECK: d_n5: "Just aaaaa"
-- CHECK: d_n6: "Just aaaaaa"
-- CHECK: d_n7: "Just aaaaaaa"
-- CHECK: d_n8: "Just aaaaaaaa"
-- CHECK: d_n12: "Just aaaaaaaaaaaa"
-- CHECK: d_n16: "Just aaaaaaaaaaaaaaaa"

import Html exposing (text)


parseQuoted : String -> Maybe String
parseQuoted s =
    case String.uncons s of
        Just ( '"', rest ) ->
            collect rest ""

        _ ->
            Nothing


collect : String -> String -> Maybe String
collect s acc =
    case String.uncons s of
        Nothing ->
            Nothing

        Just ( '"', _ ) ->
            Just acc

        Just ( c, rest ) ->
            collect rest (acc ++ String.fromChar c)


showResult : Maybe String -> String
showResult m =
    case m of
        Just s ->
            if s == "" then
                "Just"

            else
                "Just " ++ s

        Nothing ->
            "Nothing"


makeRuntime : Int -> String
makeRuntime n =
    "\"" ++ String.repeat n "a" ++ "\""


main =
    let
        log n =
            Debug.log ("d_n" ++ String.fromInt n) (showResult (parseQuoted (makeRuntime n)))

        _ = log 0
        _ = log 1
        _ = log 2
        _ = log 3
        _ = log 4
        _ = log 5
        _ = log 6
        _ = log 7
        _ = log 8
        _ = log 12
        _ = log 16
    in
    text "done"
