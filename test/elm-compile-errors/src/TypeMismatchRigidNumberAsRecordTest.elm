module TypeMismatchRigidNumberAsRecordTest exposing (..)

{-| Returning a record where the annotation promises a `number` is rejected with a TYPE MISMATCH.

`f : number -> number` with `f x = { y = 1 }`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as record
-- CHECK: -- TYPE MISMATCH -

f : number -> number
f x = { y = 1 }
