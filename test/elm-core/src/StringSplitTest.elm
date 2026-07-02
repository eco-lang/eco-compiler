module StringSplitTest exposing (main)

{-| G3/E17: String.split (no gated coverage today). Results are re-joined with "|"
so the assertions do not depend on how a List String renders. Single-char,
multi-char, and trailing-separator cases, plus a piece count.
-}

-- CHECK: split_comma: "a|b|c"
-- CHECK: split_multichar: "ab|cd"
-- CHECK: split_trailing: "a|"
-- CHECK: split_count: 3

import Html exposing (text)


main =
    let
        _ =
            Debug.log "split_comma" (String.join "|" (String.split "," "a,b,c"))

        _ =
            Debug.log "split_multichar" (String.join "|" (String.split "::" "ab::cd"))

        _ =
            Debug.log "split_trailing" (String.join "|" (String.split "," "a,"))

        _ =
            Debug.log "split_count" (List.length (String.split "," "a,b,c"))
    in
    text "done"
