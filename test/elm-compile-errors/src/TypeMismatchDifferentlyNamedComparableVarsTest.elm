module TypeMismatchDifferentlyNamedComparableVarsTest exposing (..)

{-| TYPE MISMATCH: differently named comparable vars.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, differently named comparable vars
-- CHECK: -- TYPE MISMATCH -

type A = A

type B = B

lex : comparable -> comparable
lex v = v

lex2 : comparable2 -> comparable2
lex2 v = v

x = [ ( A, lex ), ( B, lex2 ) ]
