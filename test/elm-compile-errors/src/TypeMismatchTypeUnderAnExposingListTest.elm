module TypeMismatchTypeUnderAnExposingListTest exposing (..)

{-| TYPE MISMATCH: type under an exposing list.

From `SourceIR.TypeCheckFailsCases` (`printingCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, type under an exposing list
-- CHECK: -- TYPE MISMATCH -
-- CHECK: This `Just` call produces:

import Maybe exposing (Maybe)
import Tuple exposing (first, pair)
import List exposing (map)

x : Int
x = Just 1
