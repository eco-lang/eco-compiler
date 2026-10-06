module RootStackJsonLargeKeyValueTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4):
`Json.Decode.keyValuePairs` on a JSON object with more keys than per-64 rooting can hold.

The key-value decoder roots its pairs in 64-element chunks (`runDecoder` in
elm-kernel-cpp/src/json/JsonExports.cpp): n/64 records, which overflows above 4,194,304 pairs.
RootStackJsonKeyValueTest (70,000 pairs) passes.
-}

-- CHECK: pairs: Ok 4300000

import Html exposing (text)
import Json.Decode as D
import Json.Encode as E


pad : Int -> String
pad n =
    String.padLeft 7 '0' (String.fromInt n)


{-| 4,300,000 boxed strings: more than the chunk-chain cap (`chunkChainFits`: a quarter of the 128 MB
nursery) and more than 64 × 65,536 = 4,194,304, so per-64 rooting overflows too.
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
