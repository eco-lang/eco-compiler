module NonAsciiIdentifierTest exposing (main)

{-| Pins that `café` is read as one identifier: Compiler.Parse.Variable
classifies a non-ASCII character by its Unicode code point (it once decoded
UTF-16 strings as UTF-8 bytes and rejected the name).
Unit test: compiler/tests/Compiler/Parse/VariableNonAsciiTest.elm.
-}

-- CHECK: NonAsciiIdentifierTest: 7

import Html exposing (text)


café : Int
café =
    7


main =
    let
        _ =
            Debug.log "NonAsciiIdentifierTest" café
    in
    text "done"
