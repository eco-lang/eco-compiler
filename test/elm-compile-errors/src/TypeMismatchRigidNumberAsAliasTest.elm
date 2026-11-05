module TypeMismatchRigidNumberAsAliasTest exposing (..)

{-| TYPE MISMATCH: rigid number as alias.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as alias
-- CHECK: -- TYPE MISMATCH -
-- CHECK: This `p` value is a:

type alias P = { y : Int }

p : P
p = { y = 1 }

f : number -> number
f x = p
