module CaseListConsTest exposing (main)

{-| Test case expression on List with [] and x::xs patterns.
-}

-- CHECK: sum1: 0
-- CHECK: sum2: 1
-- CHECK: sum3: 6

import Html exposing (text)


sumList list =
    case list of
        [] -> 0
        x :: xs -> x + sumList xs


main =
    let
        _ = Debug.log "sum1" (sumList [])
        _ = Debug.log "sum2" (sumList [1])
        _ = Debug.log "sum3" (sumList [1, 2, 3])
    in
    text "done"
