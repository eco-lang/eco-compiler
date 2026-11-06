module TypeMismatchUpdateOfAnEmptyRecordTest exposing (..)

{-| A record update that sets field `x` on the empty record `{}` is rejected with a TYPE
MISMATCH error.

A record update can only change fields the record already has, and the empty record has
none.

-}

-- COMPILE-ERROR: TYPE MISMATCH, update of an empty record
-- CHECK: -- TYPE MISMATCH -

r = {}

y = { r | x = 1 }
