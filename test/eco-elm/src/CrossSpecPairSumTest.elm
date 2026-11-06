module CrossSpecPairSumTest exposing (main)

{-| A top-level function that takes an `( Int, Int )` tuple and adds its two
components, destructured with a `case` expression, returns their sum.

`addPair ( 7, 23 )` is expected to log 30.

## eco

The simplest cross-function specialisation case: `addPair` only projects its tuple parameter, so the old pass cloned it as `addPair$unboxed` taking `!eco.tuple2<i64, i64>` and turned the original into a thin wrapper using `eco.from_heap`.

The cross-function aggregate unboxing pass that this fixture was written for (`EcoUnboxedAggCrossSpec`, enabled by `-enable-unboxed-agg`) was deleted in 2026-06; the test is kept as behavioural coverage for the aggregate promotion work (plans/opt-tier1-aggregate-promotion.md). Whatever ABI the back end picks, the result must match the boxed heap path.

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
