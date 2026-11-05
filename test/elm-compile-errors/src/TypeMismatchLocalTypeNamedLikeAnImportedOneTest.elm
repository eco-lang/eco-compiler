module TypeMismatchLocalTypeNamedLikeAnImportedOneTest exposing (..)

{-| TYPE MISMATCH: local type named like an imported one.

From `SourceIR.TypeCheckFailsCases` (`printingCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, local type named like an imported one
-- CHECK: -- TYPE MISMATCH -

type Maybe a = Maybe a

x : Maybe Int
x = Basics.identity (Basics.always (Maybe.Just 1) 0)
