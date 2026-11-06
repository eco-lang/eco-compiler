module CrossSpecMutualRecursiveTest exposing (main)

{-| Two mutually recursive functions pass the same `( Int, Int )` tuple back and
forth and return one of its components when the counter reaches zero.

`evenPair` and `oddPair` call each other with `n - 1`, unchanged `pair`, until
`n <= 0`; `evenPair` then returns the first component and `oddPair` the second.
Starting from `evenPair ( 1, 6 ) 5`, the countdown ends in `oddPair` at 0, so
the expected result is the second component, 6.

## eco

Exercises SCC-aware specialisation: `evenPair` and `oddPair` form a two-member SCC over a tuple parameter, so both must specialise together and the calls inside the SCC must pass the aggregate worker to worker without re-boxing at every step.

The cross-function aggregate unboxing pass that this fixture was written for (`EcoUnboxedAggCrossSpec`, enabled by `-enable-unboxed-agg`) was deleted in 2026-06; the test is kept as behavioural coverage for the aggregate promotion work (plans/opt-tier1-aggregate-promotion.md). Whatever ABI the back end picks, the result must match the boxed heap path.

-}

-- CHECK: result: 6


import Html exposing (text)


evenPair : ( Int, Int ) -> Int -> Int
evenPair pair n =
    if n <= 0 then
        case pair of
            ( a, _ ) ->
                a

    else
        oddPair pair (n - 1)


oddPair : ( Int, Int ) -> Int -> Int
oddPair pair n =
    if n <= 0 then
        case pair of
            ( _, b ) ->
                b

    else
        evenPair pair (n - 1)


main =
    let
        result =
            evenPair ( 1, 6 ) 5

        _ =
            Debug.log "result" result
    in
    text "done"
