module LssSharedSpecJoinTest exposing (main)

{-| Two different lambdas of the same type, passed to one recursive higher-order function, each keep their own behaviour.

`applyN f n acc` applies `f` to `acc` `n` times. With `n` = 3, `\x -> x + 1` from 0 gives 3, and
`\x -> x * 2` from 1 gives 8. Running the first lambda in place of the second would give 4 for `b`.

## eco

Regression test for LSS_010 (design_docs/invariants.csv): the two lambdas share one
widened-key specialization of `applyN`, whose stored type must be the join of both demands (a
two-member set), so AbiCloning (compiler/src/Compiler/MonoOpt/AbiCloning.elm) must not
fast-dispatch the internal `f acc` call. Before the fix the specialization was seeded from the
first demand only, the call was stamped with the first lambda, and `b` printed 4.

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
