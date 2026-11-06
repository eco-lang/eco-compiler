module CompilerIssue1975LetOrderCrashTest exposing (..)

{-| A type error in a let block crashes the compiler, depending on the names of its bindings.

<https://github.com/elm/compiler/issues/1975>

`func2 a` passes `a`, which `func1` uses as a record, where a `Type` is expected. Elm 0.19.1
crashes ("index out of bounds") instead of reporting the type mismatch (renaming `d` to `b` gives
the normal report).

-}

-- COMPILE-ERROR: record is not a Type
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: out of bounds

import Html


type Type
    = Constructor


func2 a =
    case a of
        Constructor ->
            1


func1 a =
    let
        d =
            a.field1

        c =
            case a.field2 of
                Constructor ->
                    func2 a
    in
    c


main =
    Html.text ""
