module CompilerIssue2207MutualRecursionSecondFunctionTest exposing (main)

{-| Using the second of two exposed, unannotated, mutually recursive functions crashes.

<https://github.com/elm/compiler/issues/2207>

`CompilerIssue2207Mutual` exposes `f` and `g`, which call each other and have no annotations.
The issue shows it in `elm repl` (`Test.g`); `elm make` of a module that uses `g` crashes the same
way in Elm 0.19.1: "Map.!: given key is not an element in the map". The program is valid and
should print `g 3: 0`.

-}

-- CHECK: g 3: 0

import CompilerIssue2207Mutual exposing (g)
import Html exposing (text)


main =
    let
        _ =
            Debug.log "g 3" (g 3)
    in
    text "done"
