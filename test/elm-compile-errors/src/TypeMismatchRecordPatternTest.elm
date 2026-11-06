module TypeMismatchRecordPatternTest exposing (..)

{-| A record pattern on an argument annotated as `Int` is rejected with a TYPE MISMATCH.

`f : Int -> Int` with `f { a } = a`: the pattern `{ a }` needs a record, but the annotation says the argument is an `Int`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, record pattern
-- CHECK: -- TYPE MISMATCH -

f : Int -> Int
f { a } = a
