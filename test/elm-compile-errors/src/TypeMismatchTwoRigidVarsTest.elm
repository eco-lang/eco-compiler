module TypeMismatchTwoRigidVarsTest exposing (..)

{-| TYPE MISMATCH: two rigid vars.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two rigid vars
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Your type annotation uses `a` and `b` as separate type

f : a -> b
f x = x
