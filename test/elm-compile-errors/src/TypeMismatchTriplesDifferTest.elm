module TypeMismatchTriplesDifferTest exposing (..)

{-| A triple whose third component does not match its annotation is rejected with a TYPE MISMATCH.

`x : ( Int, Int, Int )` is defined as `( 1, 2, "a" )`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, triples differ
-- CHECK: -- TYPE MISMATCH -

x : ( Int, Int, Int )
x = ( 1, 2, "a" )
