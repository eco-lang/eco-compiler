module TypeMismatchRigidNumberAsRigidVarTest exposing (..)

{-| Returning a value of an annotated type variable `a` where the annotation promises a `number` is rejected with a TYPE MISMATCH.

`f : number -> a -> number` with `f x y = y`: `a` and `number` are independent type variables chosen by the caller.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as rigid var
-- CHECK: -- TYPE MISMATCH -

f : number -> a -> number
f x y = y
