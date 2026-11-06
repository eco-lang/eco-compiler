module IndirectCallFloatTest exposing (main)

{-| Functions of type `Float -> Float` passed to higher-order functions, including one built with `>>`, return the right Float values.

`applyFloat f x` calls `f` once and `twiceFloat f x` calls it twice. The
functions passed are `double`, `addTen` and a local `negate` (`0.0 - x`) that
shadows the one from `Basics`.

-}

-- CHECK: apply_double: 10
-- CHECK: apply_negate: -3
-- CHECK: apply_addTen: 15
-- CHECK: twice_double: 8
-- CHECK: twice_addTen: 20
-- CHECK: compose_result: 22

import Html exposing (text)


applyFloat : (Float -> Float) -> Float -> Float
applyFloat f x =
    f x


twiceFloat : (Float -> Float) -> Float -> Float
twiceFloat f x =
    f (f x)


double : Float -> Float
double x =
    x * 2.0


negate : Float -> Float
negate x =
    0.0 - x


addTen : Float -> Float
addTen x =
    x + 10.0


main =
    let
        -- Test applyFloat with various float functions
        _ = Debug.log "apply_double" (applyFloat double 5.0)      -- 10.0
        _ = Debug.log "apply_negate" (applyFloat negate 3.0)      -- -3.0
        _ = Debug.log "apply_addTen" (applyFloat addTen 5.0)      -- 15.0

        -- Test twiceFloat (chained indirect calls)
        _ = Debug.log "twice_double" (twiceFloat double 2.0)      -- 8.0 (2 * 2 * 2)
        _ = Debug.log "twice_addTen" (twiceFloat addTen 0.0)      -- 20.0 (0 + 10 + 10)

        -- Test with composition
        doubleThenAddTen = double >> addTen
        _ = Debug.log "compose_result" (applyFloat doubleThenAddTen 6.0) -- 22.0 (6 * 2 + 10)
    in
    text "done"
