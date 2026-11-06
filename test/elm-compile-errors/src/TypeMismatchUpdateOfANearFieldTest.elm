module TypeMismatchUpdateOfANearFieldTest exposing (..)

{-| A record update that sets a misspelt field, `cuont` on a record whose only field is
`count`, is rejected with a TYPE MISMATCH error.

A record update can only change fields the record already has, and `cuont` is not one of
them.

-}

-- COMPILE-ERROR: TYPE MISMATCH, update of a near field
-- CHECK: -- TYPE MISMATCH -

r = { count = 1 }

y = { r | cuont = 2 }
