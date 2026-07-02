module StringSliceOfLargeParentGCTest exposing (main)

{-| G3/E13: a Tag_StringSlice over a large (Tag_LargeStringHeader) parent that
survives a minor GC. Unlike byte slices, getObjectSize DOES have a Tag_StringSlice
case, so string slices evacuate correctly — this should PASS, demonstrating the
contrast with the byte-slice bug (E11). source = "abcdefghij" x500 = 5000 chars
(> 4096 -> large); slice 1000..1300 = 300 chars starting at index 1000 ('a').
-}

-- CHECK: slice_len: 300
-- CHECK: slice_after_gc: "abcde"

import Html exposing (text)


main =
    let
        source =
            String.repeat 500 "abcdefghij"

        sl =
            String.slice 1000 1300 source

        churn =
            List.range 0 5000
                |> List.map (\n -> String.repeat 20 (String.fromInt n))
                |> String.concat

        -- Force slice length BEFORE churn so the slice is live across the GC.
        len0 =
            String.length sl

        afterGc =
            if (len0 > 0) && (String.length churn > 0) then
                String.left 5 sl

            else
                "?"

        _ =
            Debug.log "slice_len" len0

        _ =
            Debug.log "slice_after_gc" afterGc
    in
    text "done"
