module TypeMismatchTypeOfAModuleThatIsNotImportedTest exposing (..)

{-| TYPE MISMATCH: type of a module that is not imported.

From `SourceIR.TypeCheckFailsCases` (`printingCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, type of a module that is not imported
-- CHECK: -- TYPE MISMATCH -
-- CHECK: This `text` call produces:

import Html

x : Int
x = Html.text "a"
