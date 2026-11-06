module StringSplitTest exposing (main)

{-| Checks `String.split` with a single-character separator, a multi-character separator and a trailing separator, plus the number of pieces.

The pieces are joined with `"|"` before logging, so the expected output does
not depend on how a `List String` is printed. A trailing separator yields a
final empty piece: splitting `"a,"` on `","` gives `[ "a", "" ]`.

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
