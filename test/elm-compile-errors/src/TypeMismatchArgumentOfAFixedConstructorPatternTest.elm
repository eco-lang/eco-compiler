module TypeMismatchArgumentOfAFixedConstructorPatternTest exposing (..)

{-| TYPE MISMATCH: argument of a fixed constructor pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, argument of a fixed constructor pattern
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Want to convert a String into an Int? Use the String.t

type T = T Int

x =
    case T 1 of
        T "a" ->
            1

        _ ->
            2
