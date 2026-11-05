module TypeMismatchFloatLeftOfAppendTest exposing (..)

{-| TYPE MISMATCH: Float left of ++.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Float left of ++
-- CHECK: -- TYPE MISMATCH -
-- CHECK: The (++) operator can append List and String values, but not

f : Float
f = 1.5

x = f ++ "a"
