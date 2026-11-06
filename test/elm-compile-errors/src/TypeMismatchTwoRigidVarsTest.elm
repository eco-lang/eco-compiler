module TypeMismatchTwoRigidVarsTest exposing (..)

{-| A function annotated `a -> b` that returns its argument is rejected with a TYPE MISMATCH.

`f x = x` returns a value of type `a`, but `a` and `b` are separate type variables chosen by the caller.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two rigid vars
-- CHECK: -- TYPE MISMATCH -

f : a -> b
f x = x
