module JsArrayInitializeFromListCharUnboxedTest exposing (main)

{-| Char equivalent of `JsArrayInitializeFromListFloatUnboxedTest`:
    `Array.fromList ['a','b','c']` then `Array.foldr (::) []` to reconstruct
    the list, exercising both `initializeFromList` and `foldr` kernel paths
    on unboxed `u16` Char slots.
-}

-- CHECK: result: ['a', 'b', 'c']
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
