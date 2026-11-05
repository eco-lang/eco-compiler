module TypeMismatchFunctionInATypeArgumentTest exposing (..)

{-| TYPE MISMATCH: function in a type argument.

From `SourceIR.TypeCheckFailsCases` (`printingCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, function in a type argument
-- CHECK: -- TYPE MISMATCH -

x : Maybe (Int -> Int)
x = [ Just not ]
