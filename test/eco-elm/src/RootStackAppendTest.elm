module RootStackAppendTest exposing (main)

{-| Checks `++` and `List.append` on a list of 70,000 `String`s.

Appending `[ "x" ]` with `++` must give 70,001 elements, and `List.append` of the list with
itself 140,000.

## eco

GC shadow-root-stack pin, part of the bounded kernel rooting work
(plans/kernel-root-stack-bounded-rooting.md). The list has more boxed elements
than the 65,536 records the shadow root stack holds, so a kernel that pushes one
root record per element overflows it.

`++` goes through `Utils.append` and `List.append` through the kernel; both
rebuild the first list through `listFromUnboxables`
(runtime/src/allocator/HeapHelpers.hpp).

-}

-- CHECK: appended: 70001
-- CHECK: listAppend: 140000

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
            Debug.log "appended" (List.length (strs ++ [ "x" ]))

        _ =
            Debug.log "listAppend" (List.length (List.append strs strs))

    in
    text "done"
