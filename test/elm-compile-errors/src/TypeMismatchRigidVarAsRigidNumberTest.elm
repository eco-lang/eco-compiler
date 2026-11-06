module TypeMismatchRigidVarAsRigidNumberTest exposing (..)

{-| A function that returns its `number` argument where its annotation promises a different type variable is rejected with a TYPE MISMATCH.

`f : a -> number -> a` is defined as `f x y = y`. `a` and `number` are separate type variables chosen by the caller, so a `number` cannot stand in for an `a`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as rigid number
-- CHECK: -- TYPE MISMATCH -

f : a -> number -> a
f x y = y
