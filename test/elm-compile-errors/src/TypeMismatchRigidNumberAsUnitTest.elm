module TypeMismatchRigidNumberAsUnitTest exposing (..)

{-| Returning `()` where the annotation promises a `number` is rejected with a TYPE MISMATCH.

`f : number -> number` with `f x = ()`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as unit
-- CHECK: -- TYPE MISMATCH -

f : number -> number
f x = ()
