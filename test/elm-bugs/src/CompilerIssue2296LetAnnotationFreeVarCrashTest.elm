module CompilerIssue2296LetAnnotationFreeVarCrashTest exposing (main)

{-| A let annotation using a type variable of an unannotated outer function crashes the compiler.

<https://github.com/elm/compiler/issues/2296>

`cells : List (Html msg)` says `cells` works for every `msg`, but it is built from `children`, whose `msg` is fixed by the caller: a type error. Elm 0.19.1 crashes ("msg [rank = 2]", Type/Solve.hs:206, "thread blocked indefinitely in an MVar operation").

-}

-- COMPILE-ERROR: a type error, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: bypassed the normal error reporting

import Html exposing (text)


main =
    text "done"


asRow attrs children =
    let
        cells : List (Html.Html msg)
        cells =
            List.map asCell children
    in
    Html.div attrs cells


asCell : Html.Html msg -> Html.Html msg
asCell node =
    Html.div [] [ node ]
