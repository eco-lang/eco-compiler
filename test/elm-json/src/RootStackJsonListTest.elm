module RootStackJsonListTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `Json.Decode.list` and `Json.Decode.array` on a long JSON array of strings.

The decoders root their results in 64-element chunks and build the list through
`listFromPointers`, which pushes one root record per element.
-}

-- CHECK: list: Ok 70000
-- CHECK: array: Ok 70000

import Array
import Html exposing (text)
import Json.Decode as D
import Json.Encode as E


pad : Int -> String
pad n =
    String.padLeft 5 '0' (String.fromInt n)


{-| "00000" .. "69999": 70,000 boxed elements, more than the 65,536 records the shadow stack holds.
-}
strs : List String
strs =
    List.map pad (List.range 0 69999)


json : String
json =
    E.encode 0 (E.list E.string strs)


main =
    let
        _ =
            Debug.log "list" (Result.map List.length (D.decodeString (D.list D.string) json))

        _ =
            Debug.log "array" (Result.map Array.length (D.decodeString (D.array D.string) json))

    in
    text "done"
