module TypeMismatchRigidNumberAsRecordTest exposing (..)

{-| TYPE MISMATCH: rigid number as record.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as record
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: The `number` in your type annotation is saying that in

f : number -> number
f x = { y = 1 }
