module LssGapBranchSelect exposing (main)

{-| LSS gap probe — a BRANCH selecting between two known globals, then applied.

The set at `chosen`'s arrow has exactly two inhabitants, both named globals. A
complete analysis reports {double, triple}; the interesting failure is reporting
⊤ or an unresolved variable instead.
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
