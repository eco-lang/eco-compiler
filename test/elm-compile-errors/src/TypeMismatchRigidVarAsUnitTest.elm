module TypeMismatchRigidVarAsUnitTest exposing (..)

{-| TYPE MISMATCH: rigid var as unit.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as unit
-- CHECK: -- TYPE MISMATCH -

f : a -> a
f x = ()
