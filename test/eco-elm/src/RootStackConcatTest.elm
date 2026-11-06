module RootStackConcatTest exposing (main)

{-| Checks `List.concat` of two copies of a 70,000-element list of `String`s, which must have 140,000 elements.

## eco

GC shadow-root-stack pin, part of the bounded kernel rooting work
(plans/kernel-root-stack-bounded-rooting.md). The list has more boxed elements
than the 65,536 records the shadow root stack holds, so a kernel that pushes one
root record per element overflows it.

The kernel `List.concat` rebuilds through `listFromUnboxables`
(runtime/src/allocator/HeapHelpers.hpp).

-}

-- CHECK: concatenated: 140000

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
            Debug.log "concatenated" (List.length (List.concat [ strs, strs ]))

    in
    text "done"
