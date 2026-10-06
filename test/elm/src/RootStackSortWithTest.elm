module RootStackSortWithTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `List.sortWith` on a long list of `String`s.

As `List.sortBy`: `listFromPermutation` → `listFromUnboxables`.
-}

-- CHECK: sorted: 70000

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 5 '0' (String.fromInt n)


{-| "00000" .. "69999": 70,000 boxed elements, more than the 65,536 records the shadow stack holds.
-}
strs : List String
strs =
    List.map pad (List.range 0 69999)


main =
    let
        _ =
            Debug.log "sorted" (List.length (List.sortWith compare strs))

    in
    text "done"
