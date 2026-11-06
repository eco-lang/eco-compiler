module RootStackJsonListTest exposing (main)

{-| `Json.Decode.list` and `Json.Decode.array` decode a JSON array of 70,000 strings and return every element.

The array holds the zero-padded strings "00000" to "69999", encoded with `Json.Encode.list`,
and the test logs the length of the decoded list and of the decoded array.

## eco

A GC shadow-root-stack pin for the bounded-rooting work (plans/kernel-root-stack-bounded-rooting.md). The list and array decoders in
elm-kernel-cpp/src/json/JsonExports.cpp root their results in 64-element chunks, and the list
was once built with `listFromPointers` (runtime/src/allocator/ListOps.hpp), which pushed one
root record per element. 70,000 boxed elements is more than the 65,536 records the shadow stack
holds. test/eco-elm-json/src/RootStackJsonLargeListTest.elm covers a size where per-64 rooting
overflows too.

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


{-| The 70,000 strings "00000" to "69999".
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
