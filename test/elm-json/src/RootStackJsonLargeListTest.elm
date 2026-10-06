module RootStackJsonLargeListTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `Json.Decode.list` and
`Json.Decode.array` on a JSON array with more elements than per-64 rooting can hold.

The decoders root their results in 64-element chunks (`rootInChunks` in
elm-kernel-cpp/src/json/JsonExports.cpp): n/64 records, which overflows above 4,194,304 elements.
RootStackJsonListTest (70,000 elements) passes.
-}

-- CHECK: list: Ok 4300000
-- CHECK: array: Ok 4300000

import Array
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
    E.encode 0 (E.list E.string strs)


main =
    let
        _ =
            Debug.log "list" (Result.map List.length (D.decodeString (D.list D.string) json))

        _ =
            Debug.log "array" (Result.map Array.length (D.decodeString (D.array D.string) json))
    in
    text "done"
