module CompilerIssue1639LetAnnotationTypeVarCrashTest exposing (..)

{-| A let annotation with a type variable, inside an unannotated function, crashes the compiler.

<https://github.com/elm/compiler/issues/1639>

Elm 0.19.1 crashes ("You ran into a compiler bug", a `[rank = ...]` error) on this program. The
annotation `step : ( a, Int )` is too general (`model` is not polymorphic), so a type error
should be reported.

-}

-- COMPILE-ERROR: let annotation claims a type variable for a monomorphic value
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: compiler bug

import Html


fanOut model =
    let
        step : ( a, Int )
        step =
            ( model, 3 )
    in
    5


main =
    Html.text ""
