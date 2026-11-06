module TypeMismatchTypeOfAModuleThatIsNotImportedTest exposing (..)

{-| A value annotated `Int` but defined as `Html.text "a"` is rejected with a TYPE MISMATCH error.

`Html.text` returns a value of the `Html` module's own type, `Html msg`, so the error has to
name a type that belongs to another module.

-}

-- COMPILE-ERROR: TYPE MISMATCH, type of a module that is not imported
-- CHECK: -- TYPE MISMATCH -

import Html

x : Int
x = Html.text "a"
