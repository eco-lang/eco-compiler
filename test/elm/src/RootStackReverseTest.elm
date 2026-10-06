module RootStackReverseTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `List.reverse` on a long list of `String`s.

With chunked lists the core `List.reverse` is rerouted to the kernel (CGEN_071), which rebuilds
through `listFromUnboxables`.
-}

-- CHECK: reversed: Just "69999"

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
            Debug.log "reversed" (List.head (List.reverse strs))

    in
    text "done"
