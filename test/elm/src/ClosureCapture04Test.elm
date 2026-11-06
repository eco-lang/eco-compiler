module ClosureCapture04Test exposing (main)

{-| A lambda returned from a function captures two `Maybe Int` arguments, each
used only as the subject of a `case`, and adds the extracted values.

`Nothing` counts as 0, so the three calls log 30, 10 and 0.

-}

-- CHECK: both: 30
-- CHECK: first: 10
-- CHECK: neither: 0

import Html exposing (text)


addMaybes : Maybe Int -> Maybe Int -> (Int -> Int)
addMaybes mx my =
    \dummy ->
        let
            a =
                case mx of
                    Just x ->
                        x

                    Nothing ->
                        0

            b =
                case my of
                    Just y ->
                        y

                    Nothing ->
                        0
        in
        a + b


main =
    let
        _ = Debug.log "both" (addMaybes (Just 10) (Just 20) 0)
        _ = Debug.log "first" (addMaybes (Just 10) Nothing 0)
        _ = Debug.log "neither" (addMaybes Nothing Nothing 0)
    in
    text "done"
