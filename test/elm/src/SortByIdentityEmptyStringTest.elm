module SortByIdentityEmptyStringTest exposing (main)

{-| `List.sortBy identity` on a list of Strings that includes `""` twice.
Same F3 surface — the input Strings flow through the key extractor
unchanged, so the `""` values appear as embedded constants when the
comparator dereferences them.
-}

-- CHECK: result: ["", "", "a", "b"]

import Html exposing (text)


main =
    let
        result : List String
        result = List.sortBy identity [ "", "b", "", "a" ]

        _ = Debug.log "result" result
    in
    text "done"
