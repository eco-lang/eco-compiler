module ClosureCapture04Test exposing (main)

{-| Test closure captures two variables both used only in destructs.

Uses explicit lambda return to force nested Function nodes.
Both `mx` and `my` are captured by the inner lambda and appear only
as roots of destruct paths, never as standalone variable references.
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
