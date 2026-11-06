module TypeMismatchRigidVarAsAliasTest exposing (..)

{-| Returning a record-alias value where the annotation promises a type variable `a` is rejected with a TYPE MISMATCH.

`f : a -> a` with `f x = p`, where `p : P` and `P` is the record alias `{ y : Int }`: the caller chooses `a`, so it cannot be fixed to `P`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as alias
-- CHECK: -- TYPE MISMATCH -

type alias P = { y : Int }

p : P
p = { y = 1 }

f : a -> a
f x = p
