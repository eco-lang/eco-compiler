module CrossSpecWideRecordTest exposing (main)

{-| A function that takes a six-field record of `Int`s and adds its fields returns
their sum.

`sumWide` is called on a record literal with fields `a` to `f` set to 1 to 6,
so the expected result is 21.

## eco

Exercises the widened record field cap: at the old front-end cap of 3 fields the record was demoted to a plain `!eco.value` and the helper saw no aggregate; at the cap of 8 the six-field record reached the specialiser and `sumWide` got a worker taking six scalar `i64`s after `EcoFlattenAggBoundary`.

The cross-function aggregate unboxing pass that this fixture was written for (`EcoUnboxedAggCrossSpec`, enabled by `-enable-unboxed-agg`) was deleted in 2026-06; the test is kept as behavioural coverage for the aggregate promotion work (plans/opt-tier1-aggregate-promotion.md). Whatever ABI the back end picks, the result must match the boxed heap path.

-}

-- CHECK: result: 21


import Html exposing (text)


sumWide :
    { a : Int
    , b : Int
    , c : Int
    , d : Int
    , e : Int
    , f : Int
    }
    -> Int
sumWide r =
    r.a + r.b + r.c + r.d + r.e + r.f


main =
    let
        _ =
            Debug.log "result"
                (sumWide
                    { a = 1
                    , b = 2
                    , c = 3
                    , d = 4
                    , e = 5
                    , f = 6
                    }
                )
    in
    text "done"
