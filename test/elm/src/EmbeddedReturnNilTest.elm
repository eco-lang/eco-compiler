module EmbeddedReturnNilTest exposing (main)

{-| Test a function that conditionally returns empty list, consumed by caller.
-}

-- CHECK: r1: [2, 4]
-- CHECK: r2: []

import Html exposing (text)


filterPositiveEvens : List Int -> List Int
filterPositiveEvens xs =
    case xs of
        [] ->
            []

        x :: rest ->
            if x > 0 && modBy 2 x == 0 then
                x :: filterPositiveEvens rest

            else
                filterPositiveEvens rest


main =
    let
        r1 =
            filterPositiveEvens [ 1, 2, 3, 4, 5 ]

        r2 =
            filterPositiveEvens [ 1, 3, 5 ]

        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"
