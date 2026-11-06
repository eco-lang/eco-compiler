module CompilerIssue2182ExtensibleFunctionAliasCrashTest exposing (main)

{-| An annotation with an alias of a function type over an extensible record crashes the compiler.

<https://github.com/elm/compiler/issues/2182>

With `type alias Goal a = { a | field : Int } -> a`, Elm 0.19.1 accepts
`solution : Goal { field : Int }` / `solution = identity`, but crashes with
"Map.!: given key is not an element in the map" on `puzzle rec = rec`, which is the same function.
Both must be accepted alike.

-}

-- CHECK: done

import Html exposing (text)


type alias Goal a =
    { a | field : Int } -> a


solution : Goal { field : Int }
solution =
    identity


puzzle : Goal { field : Int }
puzzle rec =
    rec


main =
    let
        _ =
            ( solution, puzzle )
    in
    text "done"
