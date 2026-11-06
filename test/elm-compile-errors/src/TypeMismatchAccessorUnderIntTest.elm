module TypeMismatchAccessorUnderIntTest exposing (..)

{-| A field accessor function annotated as `Int` is rejected with a TYPE MISMATCH.

`x` is annotated `Int` but defined as `.name`, a function from a record with a `name` field.

-}

-- COMPILE-ERROR: TYPE MISMATCH, accessor under Int
-- CHECK: -- TYPE MISMATCH -

x : Int
x = .name
