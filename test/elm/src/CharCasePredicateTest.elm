module CharCasePredicateTest exposing (main)

{-| A `case` on a `Char` with several character-literal branches, including the
escaped literal `'\\'`, selects the branch matching the scrutinee.

`classify ','` matches the first branch and logs `"comma"`.

-}

-- CHECK: result: "comma"

import Html exposing (text)


classify : Char -> String
classify c =
    case c of
        ',' ->
            "comma"

        '{' ->
            "open brace"

        '\\' ->
            "backslash"

        _ ->
            "other"


main =
    let
        result = classify ','
        _ = Debug.log "result" result
    in
    text result
