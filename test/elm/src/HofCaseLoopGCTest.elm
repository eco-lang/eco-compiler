module HofCaseLoopGCTest exposing (main)

{-| H2.0 (plans/hof-elimination-closure-alloc-reduction.md): a case-bodied
helper inlined into a tail-recursive loop that allocates per iteration, so
the inlined mid-block eco.case executes across many nursery collections.
Pins GC-cleanliness of inlined case results (merge-block lowering) under
pressure.

Behavioral: per round, classify (modBy 3 round) over [0,1,2] cycles values
1,2,4; List.length adds 3. 15000 rounds: 5000*(1+3) + 5000*(2+3) + 5000*(4+3)
= 20000 + 25000 + 35000 = 80000.

-}

-- CHECK: result: 80000


import Html exposing (text)


classify : Int -> Int
classify n =
    case n of
        0 ->
            1

        1 ->
            2

        _ ->
            4


loop : Int -> Int -> Int
loop rounds acc =
    if rounds <= 0 then
        acc

    else
        let
            xs =
                List.range 1 3

            contribution =
                classify (modBy 3 rounds) + List.length xs
        in
        loop (rounds - 1) (acc + contribution)


main =
    let
        _ =
            Debug.log "result" (loop 15000 0)
    in
    text "done"
