module CompilerIssue1985SomeTypeHelper exposing (TheType(..))

{-| Exposes a type named `TheType`, with its constructor, for
`CompilerIssue1985ImportOrderTypeAmbiguityTest`.

Another module imported by that test exposes a type alias with the same name, so an unqualified
`TheType` there is ambiguous. Elm 0.19.1 does not report it and silently uses the last import.

<https://github.com/elm/compiler/issues/1985>

-}


{-| A wrapper around one value of any type.
-}
type TheType a
    = Boxed a
