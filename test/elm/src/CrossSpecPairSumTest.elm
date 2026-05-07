module CrossSpecPairSumTest exposing (main)

{-| Phase 3 cross-function specialisation integration test.

A top-level helper `addPair : (Int, Int) -> Int` takes a 2-tuple of
primitives and projects both fields. Under `-enable-unboxed-agg`, the
EcoUnboxedAggCrossSpec pass clones it as `addPair$unboxed` with
`!eco.tuple2<i64, i64>` parameter and rewrites the original body into a
thin wrapper using `eco.from_heap`. Behaviour must match the heap path.

-}

-- CHECK: result: 30


import Html exposing (text)


addPair : ( Int, Int ) -> Int
addPair pair =
    case pair of
        ( a, b ) ->
            a + b


main =
    let
        _ =
            Debug.log "result" (addPair ( 7, 23 ))
    in
    text "done"
