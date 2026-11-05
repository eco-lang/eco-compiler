module TypeMismatchRigidVarAsTupleTest exposing (..)

{-| TYPE MISMATCH: rigid var as tuple.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as tuple
-- CHECK: -- TYPE MISMATCH -

f : a -> a
f x = ( 1, 2 )
