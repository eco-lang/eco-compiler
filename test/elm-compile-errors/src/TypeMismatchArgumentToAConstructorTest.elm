module TypeMismatchArgumentToAConstructorTest exposing (..)

{-| TYPE MISMATCH: argument to a constructor.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, argument to a constructor
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Want to convert a String into an Int? Use the String.t

type T = T Int

x = T "s"
