module TypeMismatchRigidVarAgainstItsListTest exposing (..)

{-| Returning an argument of type `a` where the annotation says `List a` is rejected with a TYPE MISMATCH.

`f : a -> List a` with `f x = x`: `a` would have to equal `List a`, which no type does.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var against its list
-- CHECK: -- TYPE MISMATCH -

f : a -> List a
f x = x
