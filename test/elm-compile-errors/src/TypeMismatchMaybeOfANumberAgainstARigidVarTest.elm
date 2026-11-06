module TypeMismatchMaybeOfANumberAgainstARigidVarTest exposing (..)

{-| Returning `Just 1` from a function annotated `a -> a` is rejected with a TYPE MISMATCH.

The type variable `a` in the annotation is rigid: the function must work for any
`a` the caller chooses, so its body cannot return a specific type such as a
`Maybe` of a number.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Maybe of a number against a rigid var
-- CHECK: -- TYPE MISMATCH -

f : a -> a
f x = Just 1
