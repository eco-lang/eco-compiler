module TypeMismatchMaybeConsedOntoAListOfStringsTest exposing (..)

{-| TYPE MISMATCH: Maybe consed onto a list of strings.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Maybe consed onto a list of strings
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Lists need ALL elements to be the same type though.

x = Just 1 :: [ "a" ]
