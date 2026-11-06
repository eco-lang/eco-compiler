module EmbeddedNilRecursiveTest exposing (main)

{-| A recursive function that returns `[]` for an empty list builds the doubled
positive elements of its input, skipping the rest.
-}

-- CHECK: result: [2,4,6]

import Html exposing (text)


doublePositive : List Int -> List Int
doublePositive xs =
    case xs of
        [] ->
            []

        x :: rest ->
            if x > 0 then
                (x * 2) :: doublePositive rest

            else
                doublePositive rest


main =
    let
        result =
            doublePositive [ -1, 1, 0, 2, -3, 3 ]

        _ = Debug.log "result" result
    in
    text "done"
