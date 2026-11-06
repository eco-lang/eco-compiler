module RootStackAppendLargeTest exposing (main)

{-| Checks `++` and `List.concat` on a list of 4,300,000 `String`s.

Appending `[ "x" ]` must give 4,300,001 elements, and concatenating the list with itself
8,600,000.

## eco

GC shadow-root-stack pin, part of the bounded kernel rooting work
(plans/kernel-root-stack-bounded-rooting.md). Below the `chunkChainFits` cap
(runtime/src/allocator/HeapHelpers.hpp) the append kernels fill a chunk chain
and root nothing per element, which is why
test/eco-elm/src/RootStackAppendTest.elm passes. 4,300,000 boxed strings exceed
that cap (a quarter of the 128 MB nursery) and also 64 x 65,536 = 4,194,304, so
the fallback to `listFromUnboxables`, which pushes one root record per boxed
element, would overflow even with per-64 rooting.

-}

-- CHECK: appended: 4300001
-- CHECK: concatenated: 8600000

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 7 '0' (String.fromInt n)


{-| The 4,300,000 seven-digit strings "0000000" to "4299999", in ascending order.
-}
strs : List String
strs =
    List.map pad (List.range 0 4299999)


main =
    let
        _ =
            Debug.log "appended" (List.length (strs ++ [ "x" ]))

        _ =
            Debug.log "concatenated" (List.length (List.concat [ strs, strs ]))
    in
    text "done"
