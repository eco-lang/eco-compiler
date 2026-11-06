module RootStackJsonLargeListTest exposing (main)

{-| `Json.Decode.list` and `Json.Decode.array` decode a JSON array of 4,300,000 strings and return every element.

The array holds the zero-padded strings "0000000" to "4299999", encoded with
`Json.Encode.list`, and the test logs the length of the decoded list and of the decoded array.

## eco

A GC shadow-root-stack pin for the bounded-rooting work (plans/kernel-root-stack-bounded-rooting.md). The list and array decoders in
elm-kernel-cpp/src/json/JsonExports.cpp once rooted their results in 64-element chunks: n/64
records, which overflows the 65,536-record shadow stack above 64 x 65,536 = 4,194,304 elements.
4,300,000 is above that, and also above the chunk-chain cap (`chunkChainFits` in
runtime/src/allocator/HeapHelpers.hpp, a quarter of the 128 MB nursery).
test/eco-elm-json/src/RootStackJsonListTest.elm is the 70,000-element variant.

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


{-| The 4,300,000 strings "0000000" to "4299999".
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
