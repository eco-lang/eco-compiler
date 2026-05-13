module SortEmptyStringInListTest exposing (main)

{-| `List.sort` on `List String` that includes `""` twice. `List.sort`
is `List.sortBy identity`, hitting the same F3 site. Worth a separate
file because frontends may special-case `List.sort`.
-}

-- CHECK: result: ["", "", "a", "b"]

import Html exposing (text)


main =
    let
        result : List String
        result = List.sort [ "", "b", "", "a" ]

        _ = Debug.log "result" result
    in
    text "done"
