module RootStackSortByTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `List.sortBy` on a long list of `String`s.

The sort family rebuilds its result through `listFromPermutation` → `listFromUnboxables`,
which pushes one root record per boxed element.
-}

-- CHECK: sorted: 70000
-- CHECK: head: Just "00000"

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 5 '0' (String.fromInt n)


{-| "00000" .. "69999": 70,000 boxed elements, more than the 65,536 records the shadow stack holds.
-}
strs : List String
strs =
    List.map pad (List.range 0 69999)


{-| The same strings, "69999" down to "00000", built without `List.reverse` (itself a pinned
kernel).
-}
descending : List String
descending =
    List.map (\i -> pad (69999 - i)) (List.range 0 69999)


main =
    let
        _ =
            Debug.log "sorted" (List.length (List.sortBy identity descending))

        _ =
            Debug.log "head" (List.head (List.sortBy identity descending))

    in
    text "done"
