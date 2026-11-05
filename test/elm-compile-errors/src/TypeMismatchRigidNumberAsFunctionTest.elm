module TypeMismatchRigidNumberAsFunctionTest exposing (..)

{-| TYPE MISMATCH: rigid number as function.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as function
-- CHECK: -- TYPE MISMATCH -

f : number -> number
f x = \y -> y
