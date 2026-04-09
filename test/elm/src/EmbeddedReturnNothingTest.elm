module EmbeddedReturnNothingTest exposing (main)

{-| Test a function that conditionally returns Nothing, consumed by caller.
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
