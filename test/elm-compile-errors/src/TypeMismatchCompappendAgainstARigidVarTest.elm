module TypeMismatchCompappendAgainstARigidVarTest exposing (..)

{-| TYPE MISMATCH: compappend against a rigid var.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, compappend against a rigid var
-- CHECK: -- TYPE MISMATCH -
-- CHECK: compappend

f : a -> Int
f x = always 0 (\b -> if b ++ b < b then [ x, b ] else [])
