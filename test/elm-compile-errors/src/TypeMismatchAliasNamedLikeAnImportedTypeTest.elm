module TypeMismatchAliasNamedLikeAnImportedTypeTest exposing (..)

{-| TYPE MISMATCH: alias named like an imported type.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, alias named like an imported type
-- CHECK: -- TYPE MISMATCH -

type alias Bool = Int

b : Bool
b = 1

y = [ b, Basics.True ]
