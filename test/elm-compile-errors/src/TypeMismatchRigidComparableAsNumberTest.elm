module TypeMismatchRigidComparableAsNumberTest exposing (..)

{-| TYPE MISMATCH: rigid comparable as number.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid comparable as number
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Your type annotation uses `comparable` and `number` as

f : comparable -> number
f x = x
