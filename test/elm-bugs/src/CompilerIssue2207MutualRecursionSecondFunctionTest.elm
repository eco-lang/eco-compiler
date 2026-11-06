module CompilerIssue2207MutualRecursionSecondFunctionTest exposing (main)

{-| The second of two exposed, unannotated, mutually recursive functions can be used from another
module.

<https://github.com/elm/compiler/issues/2207>

`CompilerIssue2207Mutual` exposes `f` and `g`, which call each other and have no annotations. Elm
0.19.1 crashes when a module uses `g`, in `elm make` as in `elm repl`: "Map.!: given key is not an
element in the map". The program is valid and should print `g 3: 0`.

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
