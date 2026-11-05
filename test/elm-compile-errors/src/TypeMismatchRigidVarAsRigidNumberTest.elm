module TypeMismatchRigidVarAsRigidNumberTest exposing (..)

{-| TYPE MISMATCH: rigid var as rigid number.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as rigid number
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Your type annotation uses `number` and `a` as separate

f : a -> number -> a
f x y = y
