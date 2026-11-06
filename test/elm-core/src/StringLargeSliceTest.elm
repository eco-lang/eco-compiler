module StringLargeSliceTest exposing (main)

{-| Checks that `String.slice` on a 500-character string returns a 250-character slice with the right content at both ends.

The source is `"abcdefghij"` repeated 50 times. `String.slice 100 350` starts
at index 100, which holds `'a'`, and stops before index 350, so the slice
begins `"abcde"` and its last character is the `'j'` at index 349.

-}

-- CHECK: slice_len: 250
-- CHECK: slice_head: "abcde"
-- CHECK: slice_tail: "fghij"

import Html exposing (text)


main =
    let
        source =
            String.repeat 50 "abcdefghij"

        sl =
            String.slice 100 350 source

        _ =
            Debug.log "slice_len" (String.length sl)

        _ =
            Debug.log "slice_head" (String.left 5 sl)

        _ =
            Debug.log "slice_tail" (String.right 5 sl)
    in
    text "done"
