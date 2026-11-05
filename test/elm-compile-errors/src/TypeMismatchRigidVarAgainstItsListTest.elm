module TypeMismatchRigidVarAgainstItsListTest exposing (..)

{-| TYPE MISMATCH: rigid var against its list.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var against its list
-- CHECK: -- TYPE MISMATCH -
-- CHECK: List a

f : a -> List a
f x = x
