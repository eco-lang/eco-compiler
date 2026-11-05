module TypeMismatchMaybeOfANumberAgainstARigidVarTest exposing (..)

{-| TYPE MISMATCH: Maybe of a number against a rigid var.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Maybe of a number against a rigid var
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Maybe number

f : a -> a
f x = Just 1
