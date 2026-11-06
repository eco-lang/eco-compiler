module CompilerIssue1979OpaqueHelper exposing (Opaque, make)

{-| Exposes the type `Opaque` without its constructor, for
`CompilerIssue1979ImportOpaqueConstructorsTest`.

An importer may name the type and obtain a value through `make`, but may not use or import the
constructor. Elm 0.19.1 wrongly accepts `exposing (Opaque(..))` from this module instead of
reporting an import error.

<https://github.com/elm/compiler/issues/1979>

-}


{-| A type whose constructor stays private to this module.
-}
type Opaque
    = Opaque


{-| The one value of `Opaque`.
-}
make : Opaque
make =
    Opaque
