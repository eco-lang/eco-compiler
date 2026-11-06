module StringRopeContentTest exposing (main)

{-| Checks that a 140000-character string built by 1400 successive appends has the right length and intact content at both ends.

Each append adds `"abcdefghij"` repeated 10 times to the end of the
accumulator, so the first and the last ten characters must both be
`"abcdefghij"`.

-}

-- CHECK: rope_len: 140000
-- CHECK: rope_head: "abcdefghij"
-- CHECK: rope_tail: "abcdefghij"

import Html exposing (text)


main =
    let
        chunk =
            String.repeat 10 "abcdefghij"

        big =
            List.foldl (\_ acc -> acc ++ chunk) "" (List.range 1 1400)

        _ =
            Debug.log "rope_len" (String.length big)

        _ =
            Debug.log "rope_head" (String.left 10 big)

        _ =
            Debug.log "rope_tail" (String.right 10 big)
    in
    text "done"
