module IndirectCallFloatTest exposing (main)

{-| Test indirect calls (higher-order functions) with Float return types.
This exercises the f64 result conversion path in closure calls.
-}

-- CHECK: apply_double: 10
-- CHECK: apply_negate: -3
-- CHECK: apply_addTen: 15
-- CHECK: twice_double: 8
-- CHECK: twice_addTen: 20
-- CHECK: compose_result: 22

import Html exposing (text)


-- Higher-order function that applies a Float->Float function
applyFloat : (Float -> Float) -> Float -> Float
applyFloat f x =
    f x


-- Higher-order function that applies a Float->Float function twice
twiceFloat : (Float -> Float) -> Float -> Float
twiceFloat f x =
    f (f x)


-- Simple float operations to pass as closures
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
