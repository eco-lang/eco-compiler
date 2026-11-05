module TypeMismatchImportedTypeNamedLikeAnAliasTest exposing (..)

{-| TYPE MISMATCH: imported type named like an alias.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, imported type named like an alias
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Test.Bool

type alias Bool = Int

b : Bool
b = 1

y = [ Basics.True, b ]
