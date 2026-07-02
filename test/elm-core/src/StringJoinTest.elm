module StringJoinTest exposing (main)

{-| G3/E18: String.join direct (previously only tested indirectly). Multi-char
separator, empty separator, empty list, and singleton list.
-}

-- CHECK: join1: "a, b, c"
-- CHECK: join_empty_sep: "xy"
-- CHECK: join_empty_list: ""
-- CHECK: join_single: "only"

import Html exposing (text)


main =
    let
        _ =
            Debug.log "join1" (String.join ", " [ "a", "b", "c" ])

        _ =
            Debug.log "join_empty_sep" (String.join "" [ "x", "y" ])

        _ =
            Debug.log "join_empty_list" (String.join "-" [])

        _ =
            Debug.log "join_single" (String.join "-" [ "only" ])
    in
    text "done"
