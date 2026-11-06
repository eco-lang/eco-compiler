module StringSourceSweepRegressionETest exposing (main)

{-| Checks that a small character-by-character parser gives the same answer for the string `"\"hi\""` however that string was built.

`parseQuoted` reads a leading `"` with `String.uncons`, then collects
characters up to the next `"`. It is run on the same four characters made as a
literal, by two and by three appends, by `String.fromList`, by `String.left`
of a longer literal, and by reversing a literal twice; each must give
`Just "hi"`. A last case appends `"\""`, `"x"` and `"\""` and must give `Just "x"`.

-}

-- CHECK: e14_literal: "Just hi"
-- CHECK: e15_2append: "Just hi"
-- CHECK: e16_3append: "Just hi"
-- CHECK: e17_fromList: "Just hi"
-- CHECK: e18_leftOfLonger: "Just hi"
-- CHECK: e20_reverseTwice: "Just hi"
-- CHECK: eRt_len3: "Just x"

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
            "Just " ++ s

        Nothing ->
            "Nothing"


main =
    let
        e14 =
            "\"hi\""

        e15 =
            "\"" ++ "hi\""

        e16 =
            "\"" ++ "hi" ++ "\""

        e17 =
            String.fromList [ '"', 'h', 'i', '"' ]

        e18 =
            String.left 4 "\"hi\"xxx"

        e20 =
            String.reverse (String.reverse "\"hi\"")

        rtLen3 =
            "\"" ++ "x" ++ "\""

        _ =
            Debug.log "e14_literal" (showResult (parseQuoted e14))

        _ =
            Debug.log "e15_2append" (showResult (parseQuoted e15))

        _ =
            Debug.log "e16_3append" (showResult (parseQuoted e16))

        _ =
            Debug.log "e17_fromList" (showResult (parseQuoted e17))

        _ =
            Debug.log "e18_leftOfLonger" (showResult (parseQuoted e18))

        _ =
            Debug.log "e20_reverseTwice" (showResult (parseQuoted e20))

        _ =
            Debug.log "eRt_len3" (showResult (parseQuoted rtLen3))
    in
    text "done"
