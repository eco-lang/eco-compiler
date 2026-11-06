module JsArrayInitializeFromListCharUnboxedTest exposing (main)

{-| `Array.foldr (::) []` rebuilds the `List Char` an `Array` was made from with `Array.fromList`.

The list `['a', 'b', 'c']` is logged after the round trip and compared with the original.

## eco

The Char counterpart of test/eco-elm-core/src/JsArrayInitializeFromListFloatUnboxedTest.elm. It exercises the `initializeFromList` and `foldr` JsArray kernel paths (elm-kernel-cpp/src/core/JsArray.cpp) on unboxed Char slots.

-}

-- CHECK: result: ['a','b','c']
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        original = ['a', 'b', 'c']
        arr = Array.fromList original
        reconstructed = Array.foldr (::) [] arr
        _ = Debug.log "result" reconstructed
        _ = Debug.log "match" (reconstructed == original)
    in
    text "done"
