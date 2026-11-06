module SortWithCompareEmptyStringTest exposing (main)

{-| `List.sortWith compare` on a list of Strings that contains `""` twice puts both empty strings first.

`[ "", "b", "a", "" ]` sorts to `["","","a","b"]`.
-}

-- CHECK: result: ["","","a","b"]

import Html exposing (text)


main =
    let
        result : List String
        result = List.sortWith compare [ "", "b", "a", "" ]

        _ = Debug.log "result" result
    in
    text "done"
