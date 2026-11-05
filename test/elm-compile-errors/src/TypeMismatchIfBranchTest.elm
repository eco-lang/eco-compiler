module TypeMismatchIfBranchTest exposing (..)

{-| TYPE MISMATCH: if branch.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, if branch
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: All branches in an `if` must produce the same type of

x = if True then 1 else "a"
