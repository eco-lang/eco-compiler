module TopLevelFunctionValueOnceTest exposing (main)

{-| A top-level value is evaluated once, even when its type becomes a function.
`P` wraps a function and is erased (`EraseWrappers`), so `parser : P` has a
function type, and `GlobalOptimize` makes every function-typed global a closure.
That closure used to re-evaluate `build 3` on every call, logging "build" before
each result. Expected output from elm make + node.

-}

-- CHECK: build: 3
-- CHECK: r1: 4
-- CHECK-NEXT: r2: 5
-- CHECK-NEXT: r3: 6

import Html exposing (text)


type P
    = P (Int -> Int)


build : Int -> P
build k =
    let
        _ =
            Debug.log "build" k
    in
    P (\x -> x + k)


parser : P
parser =
    build 3


run : P -> Int -> Int
run (P f) x =
    f x


main =
    let
        r1 =
            Debug.log "r1" (run parser 1)

        r2 =
            Debug.log "r2" (run parser (r1 - 2))

        r3 =
            Debug.log "r3" (run parser (r2 - 2))
    in
    text (String.fromInt r3)
