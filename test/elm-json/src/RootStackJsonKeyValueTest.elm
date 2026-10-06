module RootStackJsonKeyValueTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `Json.Decode.keyValuePairs` on a JSON object with many keys.

The key-value decoder roots its pairs in 64-element chunks and builds the list through
`listFromPointers`, which pushes one root record per element.
-}

-- CHECK: pairs: Ok 70000

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
    E.encode 0 (E.object (List.indexedMap (\i s -> ( s, E.int i )) strs))


main =
    let
        _ =
            Debug.log "pairs" (Result.map List.length (D.decodeString (D.keyValuePairs D.int) json))

    in
    text "done"
