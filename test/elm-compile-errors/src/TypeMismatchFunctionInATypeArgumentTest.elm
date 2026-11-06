module TypeMismatchFunctionInATypeArgumentTest exposing (..)

{-| The compiler rejects a list holding `Just not` as the body of a definition annotated `Maybe (Int -> Int)`, with a TYPE MISMATCH error.

The annotated type's argument is itself a function type, `Int -> Int`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, function in a type argument
-- CHECK: -- TYPE MISMATCH -

x : Maybe (Int -> Int)
x = [ Just not ]
