module TestIndexedMap exposing (main)

{-| `Array.indexedMap` passes each element's index, counting from 0, along with
the element: pairing them on `[10, 20, 30]` gives `[(0,10),(1,20),(2,30)]`.
-}

-- CHECK: indexedMap1: [(0,10),(1,20),(2,30)]

import Array
import Html exposing (text)

main =
    let
        arr = Array.fromList [10, 20, 30]
        _ = Debug.log "indexedMap1" (Array.toList (Array.indexedMap (\i v -> (i, v)) arr))
    in
    text "done"
