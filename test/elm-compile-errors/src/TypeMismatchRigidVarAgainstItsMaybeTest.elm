module TypeMismatchRigidVarAgainstItsMaybeTest exposing (..)

{-| Returning an argument of type `a` where the annotation says `Maybe a` is rejected with a TYPE MISMATCH.

`f : a -> Maybe a` with `f x = x`: `a` would have to equal `Maybe a`, which no type does.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var against its Maybe
-- CHECK: -- TYPE MISMATCH -

f : a -> Maybe a
f x = x
