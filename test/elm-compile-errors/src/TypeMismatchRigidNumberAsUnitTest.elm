module TypeMismatchRigidNumberAsUnitTest exposing (..)

{-| TYPE MISMATCH: rigid number as unit.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as unit
-- CHECK: -- TYPE MISMATCH -

f : number -> number
f x = ()
