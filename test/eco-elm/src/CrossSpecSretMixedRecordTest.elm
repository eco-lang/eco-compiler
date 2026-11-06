module CrossSpecSretMixedRecordTest exposing (main)

{-| A function that returns a tuple mixing an `Int` and a `String`, destructured
in a `let` pattern, gives back both components unchanged.

`labelled 11 "hello"` returns `( 11, "hello" )`; the test logs the `Int` as
`index` and the `String` as `label`.

## eco

`( Int, String )` mixes an `i64` and a boxed `!eco.value`. An earlier gate on `eco.return` only promoted all-primitive results and demoted this one to the boxed ABI; once lifted, the result goes through sret and the wrapper re-boxes it with a single `eco.construct.tuple2`. The fields must survive the worker/wrapper boundary.

The cross-function aggregate unboxing pass that this fixture was written for (`EcoUnboxedAggCrossSpec`, enabled by `-enable-unboxed-agg`) was deleted in 2026-06; the test is kept as behavioural coverage for the aggregate promotion work (plans/opt-tier1-aggregate-promotion.md). Whatever ABI the back end picks, the result must match the boxed heap path.

-}

-- CHECK: index: 11
-- CHECK: label: "hello"


import Html exposing (text)


labelled : Int -> String -> ( Int, String )
labelled n s =
    ( n, s )


main =
    let
        ( i, lbl ) =
            labelled 11 "hello"

        _ =
            Debug.log "index" i

        _ =
            Debug.log "label" lbl
    in
    text "done"
