module TypeMismatchRigidComparableAsANumberTest exposing (..)

{-| TYPE MISMATCH: rigid comparable as a number.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid comparable as a number
-- CHECK: -- TYPE MISMATCH -

f : comparable -> comparable
f x = 1
