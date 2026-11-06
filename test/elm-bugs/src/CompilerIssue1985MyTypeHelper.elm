module CompilerIssue1985MyTypeHelper exposing (TheType)

{-| Exposes a type alias named `TheType` for `CompilerIssue1985ImportOrderTypeAmbiguityTest`.

The alias shares its name with the custom type `TheType` exposed by
`CompilerIssue1985SomeTypeHelper`, so a module importing both unqualified has an ambiguous
`TheType`. Elm 0.19.1 does not report it and silently uses the last import.

<https://github.com/elm/compiler/issues/1985>

-}

import CompilerIssue1985SomeTypeHelper


{-| `CompilerIssue1985SomeTypeHelper.TheType` specialised to `Int`.
-}
type alias TheType =
    CompilerIssue1985SomeTypeHelper.TheType Int
