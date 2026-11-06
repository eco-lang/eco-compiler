module CrossSpecReturnPointerTupleTest exposing (main)

{-| A function that returns an `( Int, List Int )` tuple, whose result is then
matched by another function, yields the original components.

`makePair 7 [ 4, 5, 6 ]` builds the tuple, and `sumHead` adds the `Int` to the
head of the list (or returns the `Int` alone for an empty list), so the
expected result is 7 + 4 = 11.

## eco

The result tuple holds a boxed `!eco.value` (the `List Int`) next to an `i64`, so it is a mixed-kind aggregate returned through the sret ABI: the worker `makePair$unboxed` takes a leading `!llvm.ptr` out-parameter and the wrapper allocates that slot before the call.

The cross-function aggregate unboxing pass that this fixture was written for (`EcoUnboxedAggCrossSpec`, enabled by `-enable-unboxed-agg`) was deleted in 2026-06; the test is kept as behavioural coverage for the aggregate promotion work (plans/opt-tier1-aggregate-promotion.md). Whatever ABI the back end picks, the result must match the boxed heap path.

-}

-- CHECK: result: 11


import Html exposing (text)


{-| Returns a tuple of `n` and `xs`.
-}
makePair : Int -> List Int -> ( Int, List Int )
makePair n xs =
    ( n, xs )


sumHead : ( Int, List Int ) -> Int
sumHead pair =
    case pair of
        ( a, x :: _ ) ->
            a + x

        ( a, [] ) ->
            a


main =
    let
        _ =
            Debug.log "result" (sumHead (makePair 7 [ 4, 5, 6 ]))
    in
    text "done"
