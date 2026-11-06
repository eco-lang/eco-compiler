module RootStackJsonLargeKeyValueTest exposing (main)

{-| `Json.Decode.keyValuePairs` decodes a JSON object with 4,300,000 keys and returns every pair.

The object is built with `Json.Encode.object`, mapping the zero-padded keys "0000000" to
"4299999" to their index, and the test logs the length of the decoded list.

## eco

A GC shadow-root-stack pin for the bounded-rooting work (plans/kernel-root-stack-bounded-rooting.md). `runDecoder` in
elm-kernel-cpp/src/json/JsonExports.cpp once rooted the pairs in 64-element chunks: n/64
records, which overflows the 65,536-record shadow stack above 64 x 65,536 = 4,194,304 pairs.
4,300,000 is above that, and also above the chunk-chain cap (`chunkChainFits` in
runtime/src/allocator/HeapHelpers.hpp, a quarter of the 128 MB nursery), so the list cannot be
built as one chunk chain either. test/eco-elm-json/src/RootStackJsonKeyValueTest.elm is the
70,000-pair variant.

-}

-- CHECK: pairs: Ok 4300000

import Html exposing (text)
import Json.Decode as D
import Json.Encode as E


pad : Int -> String
pad n =
    String.padLeft 7 '0' (String.fromInt n)


{-| The 4,300,000 keys "0000000" to "4299999".
-}
strs : List String
strs =
    List.map pad (List.range 0 4299999)


json : String
json =
    E.encode 0 (E.object (List.indexedMap (\i s -> ( s, E.int i )) strs))


main =
    let
        _ =
            Debug.log "pairs" (Result.map List.length (D.decodeString (D.keyValuePairs D.int) json))
    in
    text "done"
