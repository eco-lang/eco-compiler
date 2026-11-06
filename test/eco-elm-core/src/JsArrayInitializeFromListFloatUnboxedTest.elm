module JsArrayInitializeFromListFloatUnboxedTest exposing (main)

{-| `Array.foldr (::) []` rebuilds the `List Float` an `Array` was made from with `Array.fromList`.

The list `[1.5, 2.5]` is logged after the round trip and compared with the original.

## eco

`Array.fromList` reaches the `initializeFromList` JsArray kernel and `Array.foldr` the `foldr` kernel (elm-kernel-cpp/src/core/JsArray.cpp). The test exercises unboxed Float elements across both kernel paths: the values must keep their bits whichever way the kernels store and hand them back. The Char form is test/eco-elm-core/src/JsArrayInitializeFromListCharUnboxedTest.elm.

-}

-- CHECK: result: [1.5,2.5]
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        original = [1.5, 2.5]
        arr = Array.fromList original
        reconstructed = Array.foldr (::) [] arr
        _ = Debug.log "result" reconstructed
        _ = Debug.log "match" (reconstructed == original)
    in
    text "done"
