module ListConcatMapTest exposing (main)

{-| `List.concatMap` concatenates the lists its function returns for each element, and gives an empty list for an empty input.

The function maps each element `x` to `[x, x]`, so `[1,2,3]` becomes `[1,1,2,2,3,3]`.

-}

-- CHECK: concatMap1: [1,1,2,2,3,3]
-- CHECK: concatMap_empty: []

import Html exposing (text)

main =
    let
        _ = Debug.log "concatMap1" (List.concatMap (\x -> [x, x]) [1, 2, 3])
        _ = Debug.log "concatMap_empty" (List.concatMap (\x -> [x, x]) [])
    in
    text "done"
