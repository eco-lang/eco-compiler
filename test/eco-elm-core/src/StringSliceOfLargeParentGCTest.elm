module StringSliceOfLargeParentGCTest exposing (main)

{-| Checks that a slice of a 5000-character string keeps its content while the program goes on to build a large unrelated string.

The source is `"abcdefghij"` repeated 500 times, and `String.slice 1000 1300`
takes 300 characters starting at index 1000, which holds `'a'`. The program
then builds `churn`, the concatenation of each number from 0 to 5000 repeated
20 times, and only afterwards reads the first five characters of the slice,
which must be `"abcde"`.

## eco

Exercises a `Tag_StringSlice` whose parent is a `Tag_LargeStringHeader` string (over 4096 characters) surviving a minor GC (runtime/src/allocator/Heap.hpp). The object-size computation (`getObjectSizeFromHeader` in runtime/src/allocator/AllocatorCommon.hpp) has a string-slice case, so the slice evacuates correctly. It was written as the contrast to the byte-slice case, test/eco-elm-bytes/src/BytesSliceOfLargeParentGCTest.elm, whose case was missing at the time. The slice length is forced before `churn` so the slice is live across the collection.

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
