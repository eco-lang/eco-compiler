module EmbeddedNothingCallbackTest exposing (main)

{-| Test passing Nothing to a callback that destructures it.
-}

-- CHECK: applied1: Nothing
-- CHECK: applied2: Just 11

import Html exposing (text)


applyToMaybe : Maybe a -> (a -> b) -> Maybe b
applyToMaybe maybe f =
    case maybe of
        Just x ->
            Just (f x)

        Nothing ->
            Nothing


main =
    let
        applied1 =
            applyToMaybe Nothing (\x -> x + 1)

        applied2 =
            applyToMaybe (Just 10) (\x -> x + 1)

        _ = Debug.log "applied1" applied1
        _ = Debug.log "applied2" applied2
    in
    text "done"
