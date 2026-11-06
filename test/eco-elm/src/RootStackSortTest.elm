module RootStackSortTest exposing (main)

{-| Checks that `List.sort` on a 70,000-element list of `String`s returns all 70,000 elements.

## eco

GC shadow-root-stack pin, part of the bounded kernel rooting work
(plans/kernel-root-stack-bounded-rooting.md). The list has more boxed elements
than the 65,536 records the shadow root stack holds, so a kernel that pushes one
root record per element overflows it.

The sort family rebuilds its result through `listFromPermutation` and then
`listFromUnboxables` (runtime/src/allocator/HeapHelpers.hpp), which pushes one
root record per boxed element.

-}

-- CHECK: sorted: 70000

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
            Debug.log "sorted" (List.length (List.sort strs))

    in
    text "done"
