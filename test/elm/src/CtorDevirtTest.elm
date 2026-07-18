module CtorDevirtTest exposing (main)

{-| E9 ctor devirtualization (LSS_015, plans/lss-dispatch-value-extraction.md §11.5).

A `Can.Normal` two-arg constructor (the `List.::` analog) is passed as a
function value to a recursion-protected HOF. Flag-on (solver+LSS) the
`f (n+3) (n+4)` dispatch site carries the singleton {g|P} and is
devirtualized to a DIRECT ctor call — the dispatch is removed entirely. The
CHECK below must print the same answer as the flag-off build (LSS_005).

Unit-level pin: compiler/tests/TestLogic/Generate/CodeGen/E9CtorDevirtTest.elm.

-}

-- CHECK: result: 7

import Html exposing (text)


type Pair
    = P Int Int
    | Q


applyP : (Int -> Int -> Pair) -> Int -> Pair
applyP f n =
    if n <= 0 then
        f (n + 3) (n + 4)

    else
        applyP f (n - 1)


main =
    let
        result =
            case applyP P 2 of
                P a b ->
                    a + b

                Q ->
                    0 - 1

        _ =
            Debug.log "result" result
    in
    text "done"
