module TypeMismatchRigidNumberAsAliasTest exposing (..)

{-| Returning a record-alias value where the annotation promises a `number` is rejected with a TYPE MISMATCH.

`f : number -> number` with `f x = p`, where `p : P` and `P` is the record alias `{ y : Int }`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as alias
-- CHECK: -- TYPE MISMATCH -

type alias P = { y : Int }

p : P
p = { y = 1 }

f : number -> number
f x = p
