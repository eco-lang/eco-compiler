module TypeMismatchRigidNumberAsMaybeTest exposing (..)

{-| Returning a `Maybe` where the annotation promises a `number` is rejected with a TYPE MISMATCH.

`f : number -> number` with `f x = Just x`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as Maybe
-- CHECK: -- TYPE MISMATCH -

f : number -> number
f x = Just x
