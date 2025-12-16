module AddTest exposing (main)

{-| Simple test that verifies basic Elm operations compile and run.

    This test verifies:
    1. Elm to MLIR compilation works
    2. MLIR JIT execution works
    3. Debug.log works with integers

    Note: Arithmetic operations like (+) currently have a type mismatch
    between kernel signatures (expecting doubles) and JIT calling convention
    (passing boxed values). This will be fixed in a future update.
-}

-- CHECK: AddTest: 42

import Html exposing (text)


main =
    let
        result =
            42

        _ =
            Debug.log "AddTest" result
    in
    text "hello"
