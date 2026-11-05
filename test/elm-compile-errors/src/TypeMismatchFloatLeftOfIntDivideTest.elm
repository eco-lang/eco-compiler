module TypeMismatchFloatLeftOfIntDivideTest exposing (..)

{-| TYPE MISMATCH: Float left of //.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Float left of //
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l

x = 1.5 // 2
