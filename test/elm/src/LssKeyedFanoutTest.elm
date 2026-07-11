module LssKeyedFanoutTest exposing (main)

{-| M4 keyed-mode fan-out: three DIFFERENT same-type lambdas through one
HOF. Unkeyed, the shared spec's set joins to {m1,m2,m3} (no upgrade,
LSS_010). Keyed under budget, each lambda gets its own applyN spec with a
singleton set — all three sites fast-dispatch. With ECO_MONO_LSS_MAX_SPECS
exhausted mid-global, later demands fall back to the widened key + join
(mixed mode). Outputs must be identical in every configuration.
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
