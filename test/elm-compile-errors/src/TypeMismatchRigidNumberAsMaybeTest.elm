module TypeMismatchRigidNumberAsMaybeTest exposing (..)

{-| TYPE MISMATCH: rigid number as Maybe.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid number as Maybe
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Use Maybe.withDefault to handle possible errors. Longe

f : number -> number
f x = Just x
