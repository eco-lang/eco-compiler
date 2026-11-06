module FunctionBasicTest exposing (main)

{-| Simple unannotated top-level functions of one and two arguments return the right values.

The test logs `add 2 3` (5), `double 5` (10) and `identity 42` (42), where
`identity` is a top-level definition in this module that shadows the one from
`Basics`.

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
