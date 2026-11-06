module RecursiveFibonacciTest exposing (main)

{-| A top-level `fib` that calls itself twice per step returns 0, 1 and 55 for 0, 1 and 10.
-}

-- CHECK: fib0: 0
-- CHECK: fib1: 1
-- CHECK: fib10: 55

import Html exposing (text)


fib n =
    if n <= 0 then
        0
    else if n == 1 then
        1
    else
        fib (n - 1) + fib (n - 2)


main =
    let
        _ = Debug.log "fib0" (fib 0)
        _ = Debug.log "fib1" (fib 1)
        _ = Debug.log "fib10" (fib 10)
    in
    text "done"
