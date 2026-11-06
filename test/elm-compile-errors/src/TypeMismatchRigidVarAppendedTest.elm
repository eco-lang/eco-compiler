module TypeMismatchRigidVarAppendedTest exposing (..)

{-| Appending two values of an unconstrained annotated type variable with `++` is rejected with a TYPE MISMATCH.

`f : a -> a` with `f x = x ++ x`: `++` needs an `appendable`, and the annotation lets the caller choose any type for `a`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var appended
-- CHECK: -- TYPE MISMATCH -

f : a -> a
f x = x ++ x
