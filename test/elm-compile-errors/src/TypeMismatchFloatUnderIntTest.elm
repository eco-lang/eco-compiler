module TypeMismatchFloatUnderIntTest exposing (..)

{-| The compiler rejects the `Float` literal `1.5` as the body of a definition annotated `Int`, with a TYPE MISMATCH error.
-}

-- COMPILE-ERROR: TYPE MISMATCH, float under Int
-- CHECK: -- TYPE MISMATCH -

x : Int
x = 1.5
