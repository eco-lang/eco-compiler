module LssKeyedFanoutTest exposing (main)

{-| Three different lambdas of the same type, passed to one recursive higher-order function, each keep their own behaviour.

`applyN f n acc` applies `f` to `acc` `n` times. With `n` = 3:

  - `a`: `\x -> x + 1` from 0 gives 3.
  - `b`: `\x -> x * 2` from 1 gives 8.
  - `c`: `\x -> x + 4` from 1 gives 13.

## eco

Exercises keyed specialization in lambda-set specialization
(plans/lss-lambda-set-specialization.md). Without keying, the shared `applyN` specialization's set
joins to all three lambdas (LSS_010 in design_docs/invariants.csv) and no call is upgraded. Keyed
under budget, each lambda gets its own `applyN` specialization with a singleton set, and all three
internal `f acc` sites fast-dispatch. With `ECO_MONO_LSS_MAX_SPECS` exhausted mid-global, later
demands fall back to the widened key and the join. Output must be the same in every configuration.

-}

-- CHECK: a: 3
-- CHECK: b: 8
-- CHECK: c: 13

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

        _ =
            Debug.log "c" (applyN (\x -> x + 4) 3 1)
    in
    text "done"
