module StringLargeSliceTest exposing (main)

{-| G3/E12: slice a source large enough that the result exceeds the 128-code-unit
tiny-slice limit, producing a real Tag_StringSlice. source = "abcdefghij" x50 =
500 chars; slice 100..350 = 250 chars starting at index 100 ('a'), ending before
350 (index 349 -> 'j'). Should pass — string slices are handled everywhere.
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
