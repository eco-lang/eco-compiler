module EmbeddedNilCaptureTest exposing (main)

{-| Test empty list captured by a closure and later pattern-matched.
-}

-- CHECK: result: "empty"

import Html exposing (text)


main =
    let
        val =
            []

        f () =
            case val of
                [] ->
                    "empty"

                _ :: _ ->
                    "nonempty"

        _ = Debug.log "result" (f ())
    in
    text "done"
