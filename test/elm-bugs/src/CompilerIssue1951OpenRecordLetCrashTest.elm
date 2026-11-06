module CompilerIssue1951OpenRecordLetCrashTest exposing (..)

{-| Unifying a closed and an open record type in let bindings crashes the compiler.

<https://github.com/elm/compiler/issues/1951>

`model` is used both as `{ future : {} }` and as `{ a | tool : () }`, which is a type error.
Elm 0.19.1 crashes ("index out of bounds") instead of reporting it.

-}

-- COMPILE-ERROR: record lacks field tool
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: out of bounds

import Html


getCircuit : { future : {} } -> {}
getCircuit _ =
    {}


toolSelected : { a | tool : () } -> ()
toolSelected _ =
    ()


sidePanelView model =
    let
        _ =
            getCircuit model

        toolButtons =
            toolSelected model
    in
    ()


main =
    Html.text ""
