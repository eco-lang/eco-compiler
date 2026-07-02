module StringRopeFoldlSliceTest exposing (main)

{-| G3/E15: fold and reverse over a rope, asserting content. big is a 40000-char
rope of ASCII (per-code-unit == per-code-point, so foldl counts 40000). reverse of
a string ending "...abcdefghij" begins "jihgfedcba".
-}

-- CHECK: rope_count: 40000
-- CHECK: rope_rev_head: "jihgfedcba"

import Html exposing (text)


main =
    let
        chunk =
            String.repeat 10 "abcdefghij"

        big =
            List.foldl (\_ acc -> acc ++ chunk) "" (List.range 1 400)

        _ =
            Debug.log "rope_count" (String.foldl (\_ n -> n + 1) 0 big)

        _ =
            Debug.log "rope_rev_head" (String.left 10 (String.reverse big))
    in
    text "done"
