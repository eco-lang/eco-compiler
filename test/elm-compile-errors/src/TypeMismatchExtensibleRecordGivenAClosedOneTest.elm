module TypeMismatchExtensibleRecordGivenAClosedOneTest exposing (..)

{-| A function annotated to return the extensible record `{ r | name : Int }` but returning the record literal `{ name = 1 }` is rejected with a TYPE MISMATCH.

The annotation's `r` stands for whatever other fields the caller's record has, so the result
must be built from the argument; a literal with only `name` does not have that type.

-}

-- COMPILE-ERROR: TYPE MISMATCH, extensible record given a closed one
-- CHECK: -- TYPE MISMATCH -

g : { r | name : Int } -> { r | name : Int }
g r = { name = 1 }
