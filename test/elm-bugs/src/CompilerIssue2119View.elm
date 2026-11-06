module CompilerIssue2119View exposing (..)

{-| Exposes a pair of mutually recursive functions with no type annotations, for
`CompilerIssue2119MutualRecursionUnannotatedTest`.

`renderView` and `renderSucc` call each other. Using them from another module is what
Elm 0.19.1 fails to compile.

<https://github.com/elm/compiler/issues/2119>

-}

import Html


{-| A natural number counted in successors: `Succ Zero` is one.
-}
type Num
    = Zero
    | Succ Num


{-| Shows the text "zero" for any `Num`, reaching `Zero` through `renderSucc`.
-}
renderView element =
    case element of
        Zero ->
            Html.text "zero"

        Succ prev ->
            renderSucc prev


{-| Returns `renderView contents`.
-}
renderSucc contents =
    renderView contents
