module CompilerIssue2001RankCrashParametricLetAnnotationTest exposing (..)

{-| A let annotation `Dict a b` on a value of an unannotated function crashes the compiler.

<https://github.com/elm/compiler/issues/2001>

Elm 0.19.1 crashes ("You ran into a compiler bug", `a [rank = 2]`). The annotation is more general
than the value, so a type error should be reported.

-}

-- COMPILE-ERROR: let annotation is too general
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: compiler bug

import Html
import Dict exposing (Dict)


type Foo a
    = Foo


toDict : Foo a -> Dict a b
toDict Foo =
    Dict.empty


fn value =
    let
        dict : Dict a b
        dict =
            toDict value
    in
    ()


main =
    Html.text ""
