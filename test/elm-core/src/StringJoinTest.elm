module StringJoinTest exposing (main)

{-| G3/E18: String.join direct (previously only tested indirectly). Multi-char
separator, empty separator, empty list, and singleton list.
-}

-- CHECK: join1: "a, b, c"
-- CHECK: join_empty_sep: "xy"
-- CHECK: join_empty_list: ""
-- CHECK: join_single: "only"
-- CHECK: join_all_empty: ""
-- CHECK: join_empties_no_sep: ""
-- CHECK: replace_empty: ""

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

        -- An all-empty result must be the Empty constant, not a zero-length
        -- object (HEAP_071): this used to abort in allocAsciiOut(0).
        _ =
            Debug.log "join_all_empty" (String.join "-" [ "" ])

        _ =
            Debug.log "join_empties_no_sep" (String.join "" [ "", "" ])

        _ =
            Debug.log "replace_empty" (String.replace "\n" "|" "")
    in
    text "done"
