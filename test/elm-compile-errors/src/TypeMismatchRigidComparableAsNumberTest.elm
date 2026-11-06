module TypeMismatchRigidComparableAsNumberTest exposing (..)

{-| Returning an annotated `comparable` value where the annotation promises a `number` is rejected with a TYPE MISMATCH.

`f : comparable -> number` with `f x = x`: the two type variables are independent and both chosen by the caller, so one cannot be returned as the other.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid comparable as number
-- CHECK: -- TYPE MISMATCH -

f : comparable -> number
f x = x
