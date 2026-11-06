module CompilerIssue2013RankCrashLambdaLetAnnotationTest exposing (..)

{-| A let annotation `b : h` in a piped lambda crashes the compiler with `[rank = 1]`.

<https://github.com/elm/compiler/issues/2013>

`t` is not polymorphic, so `b : h` is too general. Elm 0.19.1 crashes ("You ran into a compiler
bug"); it should report a type error.

-}

-- COMPILE-ERROR: let annotation is too general
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: compiler bug

import Html


someValue : Int
someValue =
    0
        |> (\t ->
                let
                    b : h
                    b =
                        t
                in
                b
           )


main =
    Html.text ""
