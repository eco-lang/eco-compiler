module TypeMismatchRigidNumberAsTupleTest exposing (..)

{-| TYPE MISMATCH: rigid number as tuple.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as tuple
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: The `number` in your type annotation is saying that in

f : number -> number
f x = ( 1, 2 )
