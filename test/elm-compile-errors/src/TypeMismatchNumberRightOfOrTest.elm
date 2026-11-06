module TypeMismatchNumberRightOfOrTest exposing (..)

{-| A number as the right operand of `||` (`True || 1`) is rejected with a TYPE MISMATCH error, because `||` takes two `Bool`s.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number right of ||
-- CHECK: -- TYPE MISMATCH -

x = True || 1
