module LssGapBranchSelect exposing (main)

{-| A function that returns one of two top-level functions from an `if` can be
called with the selected function's argument directly.

`chosen False` returns `triple`, so `chosen False 10` prints 30.

## eco

A lambda-set specialization (LSS) coverage probe: the set at `chosen`'s
result arrow has exactly two inhabitants, both named globals. A complete
analysis (compiler/src/Compiler/Monomorphize/Solver/LssInfer.elm) reports
`double` and `triple`; the failure being probed is reporting LTop or an
unresolved variable instead.

-}

-- CHECK: branchSelect: 30

import Html exposing (text)


double : Int -> Int
double n =
    n * 2


triple : Int -> Int
triple n =
    n * 3


chosen : Bool -> (Int -> Int)
chosen b =
    if b then
        double

    else
        triple


main =
    let
        _ =
            Debug.log "branchSelect" (chosen False 10)
    in
    text "hello"
