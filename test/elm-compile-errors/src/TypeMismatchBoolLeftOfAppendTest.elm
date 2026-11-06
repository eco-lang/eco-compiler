module TypeMismatchBoolLeftOfAppendTest exposing (..)

{-| A `Bool` on the left of `++` is rejected with a TYPE MISMATCH.

`x = True ++ "a"`: `++` needs an appendable (a `String` or a `List`), and `True` is neither.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Bool left of ++
-- CHECK: -- TYPE MISMATCH -

x = True ++ "a"
