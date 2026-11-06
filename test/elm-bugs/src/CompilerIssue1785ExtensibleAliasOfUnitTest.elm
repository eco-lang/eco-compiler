module CompilerIssue1785ExtensibleAliasOfUnitTest exposing (..)

{-| An extensible record alias applied to `()`, a record extending a non-record, is rejected with an error.

<https://github.com/elm/compiler/issues/1785>

Elm 0.19.1 crashes ("Used toAnnotation on a type that is not well-formed") instead of reporting
the error.

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
