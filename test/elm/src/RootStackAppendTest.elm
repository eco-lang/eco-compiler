module RootStackAppendTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `List.append` and `++` on long lists of `String`s.

`++` goes through `Utils.append` and `List.append` through the kernel; both rebuild the first list
through `listFromUnboxables`.
-}

-- CHECK: appended: 70001
-- CHECK: listAppend: 140000

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
            Debug.log "appended" (List.length (strs ++ [ "x" ]))

        _ =
            Debug.log "listAppend" (List.length (List.append strs strs))

    in
    text "done"
