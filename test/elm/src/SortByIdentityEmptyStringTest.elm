module SortByIdentityEmptyStringTest exposing (main)

{-| `List.sortBy identity` on a list of Strings that contains `""` twice puts both empty strings first.

The empty string is less than any non-empty string, so `[ "", "b", "", "a" ]`
sorts to `["","","a","b"]`.
-}

-- CHECK: result: ["","","a","b"]

import Html exposing (text)


main =
    let
        result : List String
        result = List.sortBy identity [ "", "b", "", "a" ]

        _ = Debug.log "result" result
    in
    text "done"
