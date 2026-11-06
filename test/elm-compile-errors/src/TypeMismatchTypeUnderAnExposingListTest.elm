module TypeMismatchTypeUnderAnExposingListTest exposing (..)

{-| A value annotated `Int` but defined as `Just 1` is rejected with a TYPE MISMATCH error.

The module imports `Maybe` with `Maybe` in its exposing list, alongside two other imports
with exposing lists, so the mismatched type is one the program has brought into scope
unqualified.

-}

-- COMPILE-ERROR: TYPE MISMATCH, type under an exposing list
-- CHECK: -- TYPE MISMATCH -

import Maybe exposing (Maybe)
import Tuple exposing (first, pair)
import List exposing (map)

x : Int
x = Just 1
