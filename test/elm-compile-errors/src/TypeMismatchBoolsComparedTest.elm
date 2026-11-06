module TypeMismatchBoolsComparedTest exposing (..)

{-| `True < False` is rejected with a TYPE MISMATCH, because `<` takes comparable values and `Bool` is not comparable.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Bools compared
-- CHECK: -- TYPE MISMATCH -

x = True < False
