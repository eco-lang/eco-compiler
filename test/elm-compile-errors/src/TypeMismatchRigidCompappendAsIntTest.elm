module TypeMismatchRigidCompappendAsIntTest exposing (..)

{-| TYPE MISMATCH: rigid compappend as Int.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid compappend as Int
-- CHECK: -- TYPE MISMATCH -

f : compappend -> Int
f x = x
