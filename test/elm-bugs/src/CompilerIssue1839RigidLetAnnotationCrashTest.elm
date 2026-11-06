module CompilerIssue1839RigidLetAnnotationCrashTest exposing (..)

{-| A let annotation with a free type variable, in an unannotated function, crashes the compiler.

<https://github.com/elm/compiler/issues/1839>

Elm 0.19.1 crashes ("You ran into a compiler bug", `a [rank = 2]`). The annotation
`three : List a` claims `two` is polymorphic, which it is not, so a type error should be reported.

-}

-- COMPILE-ERROR: let annotation is too general
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: compiler bug

import Html


one two =
    let
        three : List a
        three =
            two
    in
    1


main =
    Html.text ""
