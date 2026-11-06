module CompilerIssue2066RankCrashNumberFloatTest exposing (..)

{-| Annotating `number` arguments compared with a `Float` crashes the type checker with `[rank = 1]`.

<https://github.com/elm/compiler/issues/2066>

`s >= first` compares a `number` (rigid) with a `Float`. Elm 0.19.1 crashes ("You ran into a
compiler bug"); it should report a type mismatch.

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
