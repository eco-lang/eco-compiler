module Fib exposing (bench)

{-| Naive recursion: call overhead and integer arithmetic, almost no allocation. Checked
against an iterative Fibonacci.
-}


fib : Int -> Int
fib n =
    if n <= 1 then
        n

    else
        fib (n - 1) + fib (n - 2)


iterate : Int -> Int -> Int -> Int
iterate n a b =
    if n <= 0 then
        a

    else
        iterate (n - 1) b (a + b)


bench : Int -> Bool
bench n =
    fib n == iterate n 0 1
