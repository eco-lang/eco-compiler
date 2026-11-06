module EmbeddedReturnNilTest exposing (main)

{-| A recursive filter returns the empty list when no element passes, and the
caller receives it like any other list.

`filterPositiveEvens` keeps the elements that are positive and even. Applied to
`[1, 2, 3, 4, 5]` it returns `[2,4]`, and applied to `[1, 3, 5]` it returns
`[]`.

-}

-- CHECK: r1: [2,4]
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
