module RootStackTakeDropTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `List.take` and `List.drop` on long lists of `String`s.

The kernels rebuild the kept part through `listFromUnboxables`.
-}

-- CHECK: taken: 69999
-- CHECK: dropped: Just "00001"

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
            Debug.log "taken" (List.length (List.take 69999 strs))

        _ =
            Debug.log "dropped" (List.head (List.drop 1 strs))

    in
    text "done"
