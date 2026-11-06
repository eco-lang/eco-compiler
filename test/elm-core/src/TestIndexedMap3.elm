module TestIndexedMap3 exposing (main)

{-| `Array.indexedMap` with a function that ignores the index returns the
elements unchanged, `[10, 20, 30]`.
-}

-- CHECK: idx1: [10,20,30]

import Array
import Html exposing (text)

main =
    let
        arr = Array.fromList [10, 20, 30]
        _ = Debug.log "idx1" (Array.toList (Array.indexedMap (\i v -> v) arr))
    in
    text "done"
