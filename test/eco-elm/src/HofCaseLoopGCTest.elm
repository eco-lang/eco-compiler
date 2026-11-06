module HofCaseLoopGCTest exposing (main)

{-| A tail-recursive loop of 15000 iterations that calls a `case`-bodied function and builds a small list on every iteration gives the right total.

Each iteration adds `classify (modBy 3 rounds)` (1, 2 or 4 for remainders 0,
1, 2) and the length of `List.range 1 3` (3). Each remainder occurs 5000
times, so the total is 5000 * (1 + 2 + 4) + 15000 * 3 = 80000.

## eco

Exercises the HOF-elimination work (plans/hof-elimination-closure-alloc-reduction.md): a
case-bodied helper is inlined into a tail-recursive loop that allocates every
iteration, so the inlined mid-block `eco.case` runs across many nursery
collections. It pins that the merge-block lowering of inlined case results is
GC-clean under pressure.

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
