module EmbeddedNothingCaptureTest exposing (main)

{-| Test Nothing captured by a closure and later pattern-matched.
-}

-- CHECK: result: -1

import Html exposing (text)


main =
    let
        val =
            Nothing

        f () =
            case val of
                Just x ->
                    x

                Nothing ->
                    -1

        _ = Debug.log "result" (f ())
    in
    text "done"
