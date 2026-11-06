module StringJoinTest exposing (main)

{-| Checks `String.join` with a multi-character separator, an empty separator, an empty list, a single-element list, and lists of empty strings, plus `String.replace` on an empty string.

`String.join "-" [ "" ]` and `String.join "" [ "", "" ]` must both give the empty
string, as must replacing `"\n"` with `"|"` in `""`.

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

        _ =
            Debug.log "join_all_empty" (String.join "-" [ "" ])

        _ =
            Debug.log "join_empties_no_sep" (String.join "" [ "", "" ])

        _ =
            Debug.log "replace_empty" (String.replace "\n" "|" "")
    in
    text "done"
