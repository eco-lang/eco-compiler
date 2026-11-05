module TypeMismatchRigidVarAgainstItsMaybeTest exposing (..)

{-| TYPE MISMATCH: rigid var against its Maybe.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid var against its Maybe
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Maybe a

f : a -> Maybe a
f x = x
