module TypeMismatchExtensibleRecordMissingAFieldTest exposing (..)

{-| Passing `{ age = 1 }` to a function that takes `{ r | name : Int }` is rejected with a TYPE MISMATCH, because the record has no `name` field.

-}

-- COMPILE-ERROR: TYPE MISMATCH, extensible record missing a field
-- CHECK: -- TYPE MISMATCH -

g : { r | name : Int } -> Int
g r = r.name

x = g { age = 1 }
