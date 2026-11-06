module CompilerIssue1785ExtensibleAliasOfUnitTest exposing (..)

{-| An extensible record alias applied to `()` (a record extending a non-record).

<https://github.com/elm/compiler/issues/1785>

The program is ill-typed, so it must be rejected with an error. Elm 0.19.1 crashes ("Used
toAnnotation on a type that is not well-formed"); Elm 0.19.3 hangs while its memory grows without
bound. With `exposing (main)` instead of `exposing (..)`, 0.19.1 accepts the program.

-}

-- COMPILE-ERROR: a kind error, not a crash or a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html


type alias SomeType a =
    { a | one : String, two : String }


someFunction : SomeType () -> Bool
someFunction rec =
    False


main =
    Html.text ""
