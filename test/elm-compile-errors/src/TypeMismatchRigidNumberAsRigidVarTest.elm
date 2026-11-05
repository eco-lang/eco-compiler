module TypeMismatchRigidNumberAsRigidVarTest exposing (..)

{-| TYPE MISMATCH: rigid number as rigid var.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as rigid var
-- CHECK: -- TYPE MISMATCH -

f : number -> a -> number
f x y = y
