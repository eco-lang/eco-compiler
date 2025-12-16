module HelloTest exposing (main)

{-| Simple test that verifies basic Elm compilation and execution.
-}

-- CHECK: HelloTest: "hello"

import Html exposing (text)


main =
    let
        msg =
            "hello"

        _ =
            Debug.log "HelloTest" msg
    in
    text msg
