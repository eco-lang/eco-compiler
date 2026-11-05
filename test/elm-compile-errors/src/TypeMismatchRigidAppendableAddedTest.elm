module TypeMismatchRigidAppendableAddedTest exposing (..)

{-| TYPE MISMATCH: rigid appendable added.

From `SourceIR.TypeCheckFailsCases` (`rigidCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid appendable added
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: The `appendable` in your type annotation is saying tha

f : appendable -> appendable
f x = x + x
