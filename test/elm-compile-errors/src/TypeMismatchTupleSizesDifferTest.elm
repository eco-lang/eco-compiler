module TypeMismatchTupleSizesDifferTest exposing (..)

{-| A triple given where the annotation promises a pair is rejected with a TYPE MISMATCH.

`x : ( Int, Int )` is defined as `( 1, 2, 3 )`; tuples of different sizes are different types.

-}

-- COMPILE-ERROR: TYPE MISMATCH, tuple sizes differ
-- CHECK: -- TYPE MISMATCH -

x : ( Int, Int )
x = ( 1, 2, 3 )
