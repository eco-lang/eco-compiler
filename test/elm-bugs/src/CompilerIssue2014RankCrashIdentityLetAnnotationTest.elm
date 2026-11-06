module CompilerIssue2014RankCrashIdentityLetAnnotationTest exposing (..)

{-| A let annotation `b : h` in an annotated lambda crashes the compiler with `[rank = 2]`.

<https://github.com/elm/compiler/issues/2014>

`t` is not polymorphic, so `b : h` is too general. Elm 0.19.1 crashes ("You ran into a compiler
bug"); it should report a type error.

-}

-- COMPILE-ERROR: let annotation is too general
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: compiler bug

import Html


anotherIdentity : a -> a
anotherIdentity =
    \t ->
        let
            b : h
            b =
                t
        in
        b


main =
    Html.text ""
