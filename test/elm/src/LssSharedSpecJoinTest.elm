module LssSharedSpecJoinTest exposing (main)

{-| LSS_010 regression: two DIFFERENT same-type lambdas share one
widened-key specialization of `applyN`. The stored spec type must be the
annotation JOIN of both demands ({m1,m2} — not a singleton), so AbiCloning
must NOT fast-dispatch the internal `f acc` site. Before the join fix,
the spec was seeded from the first demand only ({m1}), the site was
stamped with the first lambda's evaluator, and the second caller computed
(\x -> x + 1) instead of (\x -> x * 2): "b: 4" instead of "b: 8".
-}

-- CHECK: a: 3
-- CHECK: b: 8

import Html exposing (text)


applyN : (Int -> Int) -> Int -> Int -> Int
applyN f n acc =
    if n <= 0 then
        acc

    else
        applyN f (n - 1) (f acc)


main =
    let
        _ =
            Debug.log "a" (applyN (\x -> x + 1) 3 0)

        _ =
            Debug.log "b" (applyN (\x -> x * 2) 3 1)
    in
    text "done"
