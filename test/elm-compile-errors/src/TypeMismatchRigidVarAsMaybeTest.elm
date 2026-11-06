module TypeMismatchRigidVarAsMaybeTest exposing (..)

{-| A function annotated `a -> a` that returns a `Maybe` is rejected with a TYPE MISMATCH.

`f x = Just x` returns `Maybe a`, but the annotation promises the type variable `a` itself, which the body may not specialise.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as Maybe
-- CHECK: -- TYPE MISMATCH -

f : a -> a
f x = Just x
