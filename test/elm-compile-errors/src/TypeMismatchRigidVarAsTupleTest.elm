module TypeMismatchRigidVarAsTupleTest exposing (..)

{-| A function annotated `a -> a` that returns a tuple is rejected with a TYPE MISMATCH.

`f x = ( 1, 2 )` returns a pair, but the annotation promises the type variable `a`, which the body may not specialise.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as tuple
-- CHECK: -- TYPE MISMATCH -

f : a -> a
f x = ( 1, 2 )
