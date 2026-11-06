module TypeMismatchRigidVarAsRecordTest exposing (..)

{-| A function annotated `a -> a` that returns a record is rejected with a TYPE MISMATCH.

`f x = { y = 1 }` returns a record, but the annotation promises the type variable `a`, which the body may not specialise.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as record
-- CHECK: -- TYPE MISMATCH -

f : a -> a
f x = { y = 1 }
