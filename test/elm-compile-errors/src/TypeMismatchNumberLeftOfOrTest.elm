module TypeMismatchNumberLeftOfOrTest exposing (..)

{-| A number as the left operand of `||` (`1 || True`) is rejected with a TYPE MISMATCH error, because `||` takes two `Bool`s.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number left of ||
-- CHECK: -- TYPE MISMATCH -

x = 1 || True
