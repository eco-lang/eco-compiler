module TypeMismatchDifferentlyNamedFlexVarsTest exposing (..)

{-| TYPE MISMATCH: differently named flex vars.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, differently named flex vars
-- CHECK: -- TYPE MISMATCH -

type A = A

type B = B

id1 : a -> a
id1 v = v

id2 : b -> b
id2 v = v

x = [ ( A, id1 ), ( B, id2 ) ]
