module FunctionBasicTest exposing (main)

{-| Test basic function definitions.
-}

-- CHECK: add1: 5
-- CHECK: double1: 10
-- CHECK: identity1: 42

import Html exposing (text)


add a b = a + b
double x = x * 2
identity x = x


main =
    let
        _ = Debug.log "add1" (add 2 3)
        _ = Debug.log "double1" (double 5)
        _ = Debug.log "identity1" (identity 42)
    in
    text "done"
