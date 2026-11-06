module CompilerIssue1916PhantomExtensibleAliasCrashTest exposing (..)

{-| A phantom type over an extensible record in a function alias crashes the compiler.

<https://github.com/elm/compiler/issues/1916>

Elm 0.19.1 crashes ("Map.!: given key is not an element in the map") on this valid program; it
should compile.

-}

-- CHECK: bug: ()

import Html exposing (text)


type Value r
    = Value


type alias Bug r =
    Value { r | field : () } -> ()


bug : Bug {}
bug Value =
    ()


main =
    let
        _ =
            Debug.log "bug" (bug Value)
    in
    text "done"
