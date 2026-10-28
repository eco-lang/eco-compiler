module NonAsciiIdentifierTest exposing (main)

{-| Bug: Compiler.Parse.Variable non-ASCII identifier scanning decodes UTF-16
strings as UTF-8 bytes, so `café` is not read as one identifier.
Unit test: compiler/tests/Compiler/Parse/VariableNonAsciiTest.elm.
EXPECTED TO FAIL until fixed.
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
