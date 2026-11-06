module StringRopeFoldlSliceTest exposing (main)

{-| Checks `String.foldl` and `String.reverse` over a 40000-character string built by 400 successive appends.

Each append adds `"abcdefghij"` repeated 10 times. Counting characters with
`String.foldl` must give 40000, and the reversed string must begin with
`"jihgfedcba"`.

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
