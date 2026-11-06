module CompilerIssue2066RankCrashNumberFloatTest exposing (..)

{-| Annotating `number` arguments compared with a `Float` crashes the type checker.

<https://github.com/elm/compiler/issues/2066>

In `sumHelper`, `s >= first` compares the annotated `number` argument `s` with a `Float` list
element. Elm 0.19.1 crashes ("You ran into a compiler bug"); it should report a type mismatch.

-}

-- COMPILE-ERROR: number vs Float
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: compiler bug

import Html


sum : List number -> Float
sum items =
    case items of
        [] ->
            0

        first :: rest ->
            sumHelper 0 0 0 rest


sumHelper : number -> number -> number -> List Float -> Float
sumHelper s c t items =
    case items of
        [] ->
            s + c

        first :: rest ->
            let
                correction =
                    if s >= first then
                        0

                    else
                        0
            in
            sumHelper 0 0 0 rest


main =
    Html.text ""
