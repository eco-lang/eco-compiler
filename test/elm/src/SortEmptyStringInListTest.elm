module SortEmptyStringInListTest exposing (main)

{-| `List.sort` on a list of Strings that contains `""` twice puts both empty strings first.

`[ "", "b", "", "a" ]` sorts to `["","","a","b"]`. The same input is sorted with
`List.sortBy identity` in `SortByIdentityEmptyStringTest`.
-}

-- CHECK: result: ["","","a","b"]

import Html exposing (text)


main =
    let
        result : List String
        result = List.sort [ "", "b", "", "a" ]

        _ = Debug.log "result" result
    in
    text "done"
