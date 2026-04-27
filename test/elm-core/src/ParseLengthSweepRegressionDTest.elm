module ParseLengthSweepRegressionDTest exposing (main)

{-| Category D — sweep parsing of `"<n a's>"` for n = 0..16 to pin down
which lengths fail. Hypothesis: failures cluster at small lengths that
fall into a particular allocator bucket.

Each line's expected output is `Just <body>` since the input is always
a valid JSON-like quoted string built at runtime.
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
