module TypeMismatchTwoExtensibleRecordsTest exposing (..)

{-| An extensible record returned where the annotation promises a record with a different extension variable is rejected with a TYPE MISMATCH.

`g : { r | name : Int } -> { s | name : Int }` returns its argument unchanged. `r` and `s` are separate type variables chosen by the caller, so a record extending `r` is not a record extending `s`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two extensible records
-- CHECK: -- TYPE MISMATCH -

g : { r | name : Int } -> { s | name : Int }
g r = r
