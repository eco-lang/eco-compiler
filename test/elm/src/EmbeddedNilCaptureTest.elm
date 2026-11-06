module EmbeddedNilCaptureTest exposing (main)

{-| A local function that refers to an empty list defined in the enclosing `let`
matches it against the `[]` pattern.
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
