module DebugLogLambdaBoundaryTest exposing (main)

{-| A `case` branch that returns a lambda whose parameter is named `log` can
still call `Debug.log` inside that lambda.

The parameter name `log` is the same as the function name in `Debug.log`, but
the qualified call still refers to `Debug.log`. `f True "hi"` logs `"hi"` with
the label `DebugLogLambdaBoundaryTest` and returns it, so `result` is `"hi"`.

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
