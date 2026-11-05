module TypeMismatchRigidVarAsRecordTest exposing (..)

{-| TYPE MISMATCH: rigid var as record.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as record
-- CHECK: -- TYPE MISMATCH -

f : a -> a
f x = { y = 1 }
