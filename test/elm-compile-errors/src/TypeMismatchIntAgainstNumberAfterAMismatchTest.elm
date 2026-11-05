module TypeMismatchIntAgainstNumberAfterAMismatchTest exposing (..)

{-| TYPE MISMATCH: Int against number after a mismatch.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int against number after a mismatch
-- CHECK: -- TYPE MISMATCH -
-- CHECK: ( String, Int )

n : Int
n = 1

x = [ ( 1, 1 ), ( "a", n ) ]
