module TypeMismatchRigidAppendableAddedTest exposing (..)

{-| Adding two values of an annotated `appendable` type with `+` is rejected with a TYPE MISMATCH.

`f : appendable -> appendable` with `f x = x + x`: `+` needs a `number`, and the annotation only promises `appendable`, a type variable the body may not narrow.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid appendable added
-- CHECK: -- TYPE MISMATCH -

f : appendable -> appendable
f x = x + x
