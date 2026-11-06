module TypeMismatchAliasNamedLikeAnImportedTypeTest exposing (..)

{-| A local type alias that shadows an imported type name is a different type from it, so mixing the two is rejected with a TYPE MISMATCH.

The module defines `type alias Bool = Int`, so `b : Bool` is an `Int`. The list
`[ b, Basics.True ]` puts it next to the `Bool` from `Basics`, and the two types differ.

-}

-- COMPILE-ERROR: TYPE MISMATCH, alias named like an imported type
-- CHECK: -- TYPE MISMATCH -

type alias Bool = Int

b : Bool
b = 1

y = [ b, Basics.True ]
