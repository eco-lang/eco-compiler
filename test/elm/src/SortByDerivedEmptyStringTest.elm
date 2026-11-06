module SortByDerivedEmptyStringTest exposing (main)

{-| `List.sortBy String.reverse` sorts strings by their reversed text, with the empty strings first.

The input is `[ "", "ba", "a", "" ]`, giving keys `""`, `"ab"`, `"a"` and `""`.
The empty key sorts first and `"a"` before `"ab"`, so the result is
`["","","a","ba"]`.

-}

-- CHECK: result: ["","","a","ba"]

import Html exposing (text)


main =
    let
        result : List String
        result = List.sortBy String.reverse [ "", "ba", "a", "" ]

        _ = Debug.log "result" result
    in
    text "done"
