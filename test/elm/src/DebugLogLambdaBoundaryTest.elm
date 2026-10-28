module DebugLogLambdaBoundaryTest exposing (main)

{-| Bug: Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries renames the name
inside a VarDebug node when merging a case boundary whose branch lambda has a
parameter named like the Debug function (`log`), turning Debug.log into
log_hl_0. Unit test:
compiler/tests/Compiler/LocalOpt/Typed/NormalizeLambdaBoundariesDebugNameTest.elm.
EXPECTED TO FAIL until fixed.
-}

-- CHECK: DebugLogLambdaBoundaryTest: "hi"
-- CHECK: result: "hi"

import Html exposing (text)


f : Bool -> String -> String
f b =
    case b of
        True ->
            \log -> Debug.log "DebugLogLambdaBoundaryTest" log

        False ->
            \log -> log


main =
    let
        _ =
            Debug.log "result" (f True "hi")
    in
    text "done"
