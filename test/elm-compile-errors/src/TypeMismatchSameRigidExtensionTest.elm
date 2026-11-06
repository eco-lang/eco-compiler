module TypeMismatchSameRigidExtensionTest exposing (..)

{-| An extensible record returned with a field of a different type than its annotation promises is rejected with a TYPE MISMATCH.

`g : { r | name : Int } -> { r | name : String }` returns its argument unchanged. Both sides share the extension `r`, so the records differ only in `name`, which is `Int` on one side and `String` on the other.

-}

-- COMPILE-ERROR: TYPE MISMATCH, same rigid extension
-- CHECK: -- TYPE MISMATCH -

g : { r | name : Int } -> { r | name : String }
g r = r
