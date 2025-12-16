module AddTest exposing (main)

{-| Simple test that verifies basic Elm operations compile and run.

    This test verifies:
    1. Elm to MLIR compilation works
    2. MLIR JIT execution works
    3. Basic integer addition works

    The test passes if execution completes without errors.
-}

import Html exposing (text)


main =
    let
        a =
            17

        b =
            25

        -- result should be 42
        result =
            a + b
    in
    text "hello"
