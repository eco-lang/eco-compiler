module TypeMismatchRigidVarComparedTest exposing (..)

{-| Comparing values of an unconstrained annotated type variable with `<` is rejected with a TYPE MISMATCH.

`f : a -> Bool` is defined as `f x = x < x`. `<` needs a `comparable`, and the annotation's `a` may be any type.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var compared
-- CHECK: -- TYPE MISMATCH -

f : a -> Bool
f x = x < x
