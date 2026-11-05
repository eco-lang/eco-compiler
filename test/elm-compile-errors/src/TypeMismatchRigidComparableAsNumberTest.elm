module TypeMismatchRigidComparableAsNumberTest exposing (..)

{-| TYPE MISMATCH: rigid comparable as number.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid comparable as number
-- CHECK: -- TYPE MISMATCH -

f : comparable -> number
f x = x
