module TypeMismatchRigidVarComparedTest exposing (..)

{-| TYPE MISMATCH: rigid var compared.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var compared
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Your type annotation uses type variable `a` which mean

f : a -> Bool
f x = x < x
