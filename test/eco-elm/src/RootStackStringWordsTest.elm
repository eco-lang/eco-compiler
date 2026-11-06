module RootStackStringWordsTest exposing (main)

{-| Checks that `String.words` splits a string of 70,000 space-separated words into 70,000 parts.

## eco

GC shadow-root-stack pin, part of the bounded kernel rooting work
(plans/kernel-root-stack-bounded-rooting.md). The list has more boxed elements
than the 65,536 records the shadow root stack holds, so a kernel that pushes one
root record per element overflows it.

The result reaches `listFromPointers` (runtime/src/allocator/HeapHelpers.hpp),
which pushes one root record per boxed element; `String.words` also
roots its parts in 64-element chunks.

-}

-- CHECK: words: 70000

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 5 '0' (String.fromInt n)


{-| The 70,000 five-digit strings "00000" to "69999", in ascending order.
-}
strs : List String
strs =
    List.map pad (List.range 0 69999)


main =
    let
        _ =
            Debug.log "words" (List.length (String.words (String.join " " strs)))

    in
    text "done"
