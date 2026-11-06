module CtorDevirtTest exposing (main)

{-| A two-argument custom-type constructor passed as a function value to a
recursive higher-order function builds the expected value when that function
finally calls it.

`applyP P 2` counts `n` down to 0 and then calls `P (n + 3) (n + 4)`, giving
`P 3 4`; the `case` in `main` adds the two fields, so the expected result is 7.

## eco

Exercises E9 constructor devirtualization (LSS_015 in design_docs/invariants.csv; plans/lss-dispatch-value-extraction.md). `P` is an ordinary two-argument constructor, the analogue of `List.::`, passed as a function value to a recursion-protected higher-order function. With the solver and lambda-set specialisation on, the call `f (n + 3) (n + 4)` has the singleton lambda set of `P` and becomes a direct constructor call with no dispatch. The CHECK line must print the same answer as a build with lambda-set specialisation off (LSS_005 in design_docs/invariants.csv).

The unit-level test is compiler/tests/Compiler/Monomorphize/Solver/E9CtorDevirtTest.elm.

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
