module TypeMismatchRigidVarComparedTest exposing (..)

{-| TYPE MISMATCH: rigid var compared.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var compared
-- CHECK: -- TYPE MISMATCH -

f : a -> Bool
f x = x < x
