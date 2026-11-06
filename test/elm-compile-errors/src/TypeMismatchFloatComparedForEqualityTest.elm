module TypeMismatchFloatComparedForEqualityTest exposing (..)

{-| The compiler rejects `1.5 == "a"`, an equality test between a `Float` and a `String`, with a TYPE MISMATCH error.
-}

-- COMPILE-ERROR: TYPE MISMATCH, Float compared for equality
-- CHECK: -- TYPE MISMATCH -

x = 1.5 == "a"
