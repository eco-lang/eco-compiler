module CompilerIssue1793ComparableTupleLetCrashTest exposing (..)

{-| Comparing tuples containing a `comparable` in a let binding crashes the compiler.

<https://github.com/elm/compiler/issues/1793>

Elm 0.19.1 crashes ("index out of bounds") on this valid program; it should compile.

-}

-- CHECK: f 1: True

import Html exposing (text)


f : comparable -> Bool
f x =
    let
        result =
            ( 0, x ) < ( 1, x )
    in
    result


main =
    let
        _ =
            Debug.log "f 1" (f 1)
    in
    text "done"
