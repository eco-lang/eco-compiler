module HofForwardGCPressureTest exposing (main)

{-| A let-bound lambda capturing an Int and a Bool, called once per iteration of a 20000-round tail-recursive loop that also builds a list each round, gives the right total.

Each round `step` sums `List.range 1 5` (15), adds the captured `bonus` (2), and
adds 1 when the captured `odd` is `True`. `odd` is true for odd round numbers,
so over rounds 20000 down to 1 half the rounds add 17 and half add 18:
10000 * 17 + 10000 * 18 = 350000.

## eco

Exercises the forwarded-closure path of the HOF-elimination work
(plans/hof-elimination-closure-alloc-reduction.md) under GC pressure: the let-bound lambda is
beta-reduced into straight-line code, and its captures (an Int and a Bool)
flow through that code while the per-iteration list allocation triggers
several nursery collections mid-loop. It pins that the transformed code is
GC-clean, not just arithmetically right.

-}

-- CHECK: result: 350000


import Html exposing (text)


loop : Int -> Int -> Int
loop rounds acc =
    if rounds <= 0 then
        acc

    else
        let
            odd =
                modBy 2 rounds == 1

            bonus =
                2

            step =
                \xs ->
                    List.sum xs
                        + bonus
                        + (if odd then
                            1

                           else
                            0
                          )

            contribution =
                step (List.range 1 5)
        in
        loop (rounds - 1) (acc + contribution)


main =
    let
        _ =
            Debug.log "result" (loop 20000 0)
    in
    text "done"
