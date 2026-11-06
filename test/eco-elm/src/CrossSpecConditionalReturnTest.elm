module CrossSpecConditionalReturnTest exposing (main)

{-| A function returning a tuple from either branch of an `if`, with the components in a
different order in each branch.

`pick True 7 4` is `( 7, 4 )`, which sums to `11`.

## eco

The front end lowers the `if` to an `eco.case` with `case_kind = "bool"` whose two alternatives each yield an `eco.construct.tuple2`. The return operand is therefore the case's result, not a construct; the specialiser had to walk both alternatives and retype the join to emit a `pick$unboxed` worker returning scalars, with the wrapper re-boxing the tuple.

The cross-function aggregate unboxing pass that this fixture was written for (`EcoUnboxedAggCrossSpec`, enabled by `-enable-unboxed-agg`) was deleted in 2026-06; the test is kept as behavioural coverage for the aggregate promotion work (plans/opt-tier1-aggregate-promotion.md). Whatever ABI the back end picks, the result must match the boxed heap path.

-}

-- CHECK: result: 11


import Html exposing (text)


pick : Bool -> Int -> Int -> ( Int, Int )
pick c a b =
    if c then
        ( a, b )

    else
        ( b, a )


main =
    let
        ( x, y ) =
            pick True 7 4

        _ =
            Debug.log "result" (x + y)
    in
    text "done"
