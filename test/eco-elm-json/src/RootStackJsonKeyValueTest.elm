module RootStackJsonKeyValueTest exposing (main)

{-| `Json.Decode.keyValuePairs` decodes a JSON object with 70,000 keys and returns every pair.

The object is built with `Json.Encode.object`, mapping the zero-padded keys "00000" to
"69999" to their index, and the test logs the length of the decoded list.

## eco

A GC shadow-root-stack pin for the bounded-rooting work (plans/kernel-root-stack-bounded-rooting.md). The key-value decoder in
elm-kernel-cpp/src/json/JsonExports.cpp roots its pairs in 64-element chunks, and the list was
once built with `listFromPointers` (runtime/src/allocator/ListOps.hpp), which pushed one root
record per element. 70,000 elements is more than the 65,536 records the shadow stack holds.
test/eco-elm-json/src/RootStackJsonLargeKeyValueTest.elm covers a size where per-64 rooting
overflows too.

-}

-- CHECK: pairs: Ok 70000

import Array
import Html exposing (text)
import Json.Decode as D
import Json.Encode as E


pad : Int -> String
pad n =
    String.padLeft 5 '0' (String.fromInt n)


{-| The 70,000 keys "00000" to "69999".
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
