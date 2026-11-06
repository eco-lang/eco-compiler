module CompilerIssue2119View exposing (..)

{-| Helper module for CompilerIssue2119MutualRecursionUnannotatedTest. -}

import Html


type Num
    = Zero
    | Succ Num


renderView element =
    case element of
        Zero ->
            Html.text "zero"

        Succ prev ->
            renderSucc prev


renderSucc contents =
    renderView contents
