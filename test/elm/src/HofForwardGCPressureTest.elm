module HofForwardGCPressureTest exposing (main)

{-| HOF-elimination H1 under GC pressure
(plans/hof-elimination-closure-alloc-reduction.md): drive the forwarded-
closure code path through a tail-recursive loop that also allocates lists
per iteration, so several nursery collections happen mid-loop. The
captures (an Int and a Bool) flow through beta-reduced straight-line code —
this pins that the transformed code is GC-clean, not just arithmetically
right.

Behavioral: each round adds (sum [1..5] + 2) = 17 when odd-flag is False;
20000 rounds alternate flag so half add 17, half add 18: 10000*17 +
10000*18 = 350000.

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
