module CompilerIssue1952ExtendIntCrashTest exposing (..)

{-| Extending `Int` as if it were a record crashes the compiler while reporting the error.

<https://github.com/elm/compiler/issues/1952>

`Foo Int` extends the non-record `Int`. Elm 0.19.1 starts a TYPE MISMATCH report and then
crashes ("Used toErrorType on a type that is not well-formed"); it should report the error.

-}

-- COMPILE-ERROR: extending a non-record
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: not well-formed

import Html


type alias Foo r =
    { r | foo : () }


type alias Bar =
    Foo Int


b : Bar
b =
    {}


main =
    Html.text ""
