module CovForeignTypesHelper exposing (config, secretValue)

{-| Supplies `CovForeignTypesTest` with two values from another module: one
whose annotation names a type alias this module does not expose, and a record.

An importing module cannot name `Secret`, but it can still use `secretValue`,
whose type is `Int` once the alias is expanded.

-}


{-| A name for `Int`, deliberately left out of the module's exposing list.
-}
type alias Secret =
    Int


{-| The number 41, annotated with the unexposed alias `Secret`.
-}
secretValue : Secret
secretValue =
    41


{-| A record with `x = 1` and `y = 2`, which an importer reads a field of
through the module name.
-}
config : { x : Int, y : Int }
config =
    { x = 1, y = 2 }
