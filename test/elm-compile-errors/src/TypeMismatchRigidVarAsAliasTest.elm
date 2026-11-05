module TypeMismatchRigidVarAsAliasTest exposing (..)

{-| TYPE MISMATCH: rigid var as alias.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var as alias
-- CHECK: -- TYPE MISMATCH -
-- CHECK: This `p` value is a:

type alias P = { y : Int }

p : P
p = { y = 1 }

f : a -> a
f x = p
