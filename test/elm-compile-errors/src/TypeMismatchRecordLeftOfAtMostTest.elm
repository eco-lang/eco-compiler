module TypeMismatchRecordLeftOfAtMostTest exposing (..)

{-| Comparing two records with `<=` is rejected with a TYPE MISMATCH error, because `<=` takes `comparable` operands and records are not comparable.

-}

-- COMPILE-ERROR: TYPE MISMATCH, record left of <=
-- CHECK: -- TYPE MISMATCH -

x = { a = 1 } <= { a = 1 }
