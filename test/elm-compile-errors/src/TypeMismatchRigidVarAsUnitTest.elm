module TypeMismatchRigidVarAsUnitTest exposing (..)

{-| TYPE MISMATCH: rigid var as unit.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as unit
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Your type annotation uses type variable `a` which mean

f : a -> a
f x = ()
