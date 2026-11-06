module TypeMismatchUnitPatternTest exposing (..)

{-| A function annotated `Int -> Int` whose parameter is the unit pattern `()` is rejected with
a TYPE MISMATCH error.

The pattern `()` only matches the unit type, which clashes with the annotated `Int`
argument.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unit pattern
-- CHECK: -- TYPE MISMATCH -

f : Int -> Int
f () = 1
