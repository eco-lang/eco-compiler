module TypeMismatchRigidComparableAsANumberTest exposing (..)

{-| Returning a number literal where the annotation promises a `comparable` is rejected with a TYPE MISMATCH.

`f : comparable -> comparable` with `f x = 1`: the caller chooses the `comparable` type (it may be `String`), so the literal `1` cannot stand for it.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid comparable as a number
-- CHECK: -- TYPE MISMATCH -

f : comparable -> comparable
f x = 1
