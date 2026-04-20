module JsArrayInitializeFromListFloatUnboxedTest exposing (main)

{-| Build `Array Float` from a list (internally hits
    `Elm_Kernel_JsArray_initializeFromList` via `Array.fromList`), then
    reconstruct a list explicitly via `Array.foldr (::) []` (hits
    `Elm_Kernel_JsArray_foldr`). Both kernel paths re-box unboxed slots as
    `Elm Int`; a surviving round-trip with the right values means the Elm
    wrappers rescue the bits via List.cons specialization.
-}

-- CHECK: result: [1.5, 2.5]
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
