module TypeMismatchFloatLeftOfAppendTest exposing (..)

{-| The compiler rejects a `Float` on the left of `++`, which only accepts strings and lists, with a TYPE MISMATCH error.
-}

-- COMPILE-ERROR: TYPE MISMATCH, Float left of ++
-- CHECK: -- TYPE MISMATCH -

f : Float
f = 1.5

x = f ++ "a"
