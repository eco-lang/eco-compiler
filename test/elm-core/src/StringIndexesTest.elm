module StringIndexesTest exposing (main)

{-| Checks that `String.indexes` returns every position where a substring occurs, without overlaps as in elm/core, and an empty list when it never does.

`"he"` occurs in `"he says hello"` at positions 0 and 8; `"xyz"` does not occur
in `"hello"`. `"aa"` occurs in `"aaaa"` at 0 and 2 only, and `"<"` is found at UTF-16
unit positions in a String with a non-ASCII character.

-}

-- CHECK: indexes1: [0,8]
-- CHECK: indexes_none: []
-- CHECK: indexes_no_overlap: [0,2]
-- CHECK: indexes_utf16: [1,4]

import Html exposing (text)

main =
    let
        _ = Debug.log "indexes1" (String.indexes "he" "he says hello")
        _ = Debug.log "indexes_none" (String.indexes "xyz" "hello")
        _ = Debug.log "indexes_no_overlap" (String.indexes "aa" "aaaa")
        _ = Debug.log "indexes_utf16" (String.indexes "<" "é<ab<")
    in
    text "done"
