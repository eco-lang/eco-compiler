module TypeMismatchFloatRightOfIntDivideTest exposing (..)

{-| TYPE MISMATCH: Float right of //.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Float right of //
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l

x = 2 // 1.5
