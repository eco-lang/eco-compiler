module RecursiveFibonacciTest exposing (main)

{-| Test recursion with multiple recursive calls.
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
