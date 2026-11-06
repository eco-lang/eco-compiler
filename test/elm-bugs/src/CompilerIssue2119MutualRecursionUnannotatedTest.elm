module CompilerIssue2119MutualRecursionUnannotatedTest exposing (main)

{-| An exposed, unannotated, mutually recursive function used from another module compiles and
runs.

<https://github.com/elm/compiler/issues/2119>

`CompilerIssue2119View` exposes `renderView` and `renderSucc`, which call each other and have no
type annotations. Elm 0.19.1 crashes with "Map.!: given key is not an element in the map". The
program is valid and should compile and run.

-}

-- CHECK: depth: 1

import CompilerIssue2119View as View


main =
    let
        _ =
            Debug.log "depth" (depth (View.Succ View.Zero))
    in
    View.renderView (View.Succ View.Zero)


depth : View.Num -> Int
depth n =
    case n of
        View.Zero ->
            0

        View.Succ m ->
            1 + depth m
