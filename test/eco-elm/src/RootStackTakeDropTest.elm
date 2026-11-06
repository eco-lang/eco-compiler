module RootStackTakeDropTest exposing (main)

{-| Checks `List.take` and `List.drop` on a 70,000-element list of `String`s.

`List.take 69999` must keep 69,999 elements, and `List.drop 1` must start with the second
element, `"00001"`.

## eco

Exercises the bounded GC shadow-root stack (plans/kernel-root-stack-bounded-rooting.md).
The `List.take` / `List.drop` kernels rebuild the kept part of the list through
`listFromUnboxables` (runtime/src/allocator/ListOps.cpp), rooting each boxed element.

The list holds 70,000 boxed `String`s, more than the 65,536 records the shadow
stack holds, so a kernel that pushed one root per element would overflow it.

-}

-- CHECK: taken: 69999
-- CHECK: dropped: Just "00001"

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
            Debug.log "taken" (List.length (List.take 69999 strs))

        _ =
            Debug.log "dropped" (List.head (List.drop 1 strs))

    in
    text "done"
