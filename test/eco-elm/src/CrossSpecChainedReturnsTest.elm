module CrossSpecChainedReturnsTest exposing (main)

{-| A tuple returned by one function, passed on unchanged as another function's result, and
then taken apart by a third.

`widenPair 3` is `bumpPair 6 = ( 6, 7 )`, and `sumPair` of that is `13`.

## eco

Exercises three parts of cross-function aggregate specialisation at once: result-side unboxing (`bumpPair` returns a constructed tuple), call-result propagation through the fixpoint (`widenPair` returns `bumpPair`'s result without rebuilding it, so it only specialises if a call result from an eligible callee counts as passthrough), and param-side unboxing (`sumPair` projects the tuple). Under the old pass all three helpers got `$unboxed` workers and the chain called worker to worker.

The cross-function aggregate unboxing pass that this fixture was written for (`EcoUnboxedAggCrossSpec`, enabled by `-enable-unboxed-agg`) was deleted in 2026-06; the test is kept as behavioural coverage for the aggregate promotion work (plans/opt-tier1-aggregate-promotion.md). Whatever ABI the back end picks, the result must match the boxed heap path.

-}

-- CHECK: result: 13


import Html exposing (text)


bumpPair : Int -> ( Int, Int )
bumpPair n =
    ( n, n + 1 )


widenPair : Int -> ( Int, Int )
widenPair n =
    bumpPair (n * 2)


sumPair : ( Int, Int ) -> Int
sumPair pair =
    case pair of
        ( a, b ) ->
            a + b


main =
    let
        result =
            sumPair (widenPair 3)

        _ =
            Debug.log "result" result
    in
    text "done"
