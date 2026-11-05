module TypeMismatchRigidVarAsMaybeTest exposing (..)

{-| TYPE MISMATCH: rigid var as Maybe.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as Maybe
-- CHECK: -- TYPE MISMATCH -

f : a -> a
f x = Just x
