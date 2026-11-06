module EmbeddedReturnNothingTest exposing (main)

{-| A function that returns `Nothing` for one input and `Just` for another is
consumed by a `case` in the caller.

`safeDivide` returns `Nothing` when the divisor is 0 and otherwise `Just` the
integer quotient. The caller maps `Nothing` to -1, so dividing 10 by 2 logs 5
and dividing 10 by 0 logs -1.

-}

-- CHECK: r1: 5
-- CHECK: r2: -1

import Html exposing (text)


safeDivide : Int -> Int -> Maybe Int
safeDivide a b =
    if b == 0 then
        Nothing

    else
        Just (a // b)


main =
    let
        r1 =
            case safeDivide 10 2 of
                Just x ->
                    x

                Nothing ->
                    -1

        r2 =
            case safeDivide 10 0 of
                Just x ->
                    x

                Nothing ->
                    -1

        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"
