module CovForeignTypesHelper exposing (config, secretValue)

{-| Helper module for `CovForeignTypesTest`: exposes a value whose annotation
names a type alias the module does not expose, and a record value.

Because `Secret` is not exposed, the module's interface carries the type of
`secretValue` with the alias already expanded, which an importing module's
type checker then instantiates.

-}


type alias Secret =
    Int


{-| An `Int`, typed through the unexposed alias `Secret`.
-}
secretValue : Secret
secretValue =
    41


{-| A record value, for a field access through the module name.
-}
config : { x : Int, y : Int }
config =
    { x = 1, y = 2 }
