module CompilerIssue2001RankCrashParametricLetAnnotationTest exposing (..)

{-| A let annotation `Dict a b` inside an unannotated function crashes the compiler.

<https://github.com/elm/compiler/issues/2001>

`dict` is `toDict value`, so its key type is fixed by the argument `value` of `fn`, while the
annotation claims it for any `a`. The annotation is too general, so a type error should be
reported; Elm 0.19.1 crashes ("You ran into a compiler bug") instead.

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
