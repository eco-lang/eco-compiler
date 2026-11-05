module TypeMismatchTupleSizesDifferTest exposing (..)

{-| TYPE MISMATCH: tuple sizes differ.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, tuple sizes differ
-- CHECK: -- TYPE MISMATCH -
-- CHECK: The body is a tuple of type:

x : ( Int, Int )
x = ( 1, 2, 3 )
