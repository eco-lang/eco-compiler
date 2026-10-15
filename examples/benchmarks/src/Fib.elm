module Fib exposing (bench)

{-| Naive recursion: call overhead and integer arithmetic, almost no allocation.
-}


fib : Int -> Int
fib n =
    if n <= 1 then
        n

    else
        fib (n - 1) + fib (n - 2)


bench : Int -> Int
bench n =
    fib n
