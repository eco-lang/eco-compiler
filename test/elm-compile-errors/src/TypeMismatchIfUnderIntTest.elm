module TypeMismatchIfUnderIntTest exposing (..)

{-| The compiler rejects an `if` producing strings as the body of a definition annotated `Int`, with a TYPE MISMATCH error.
-}

-- COMPILE-ERROR: TYPE MISMATCH, if under Int
-- CHECK: -- TYPE MISMATCH -

x : Int
x = if True then "a" else "b"
