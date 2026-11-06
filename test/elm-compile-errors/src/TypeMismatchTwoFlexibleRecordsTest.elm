module TypeMismatchTwoFlexibleRecordsTest exposing (..)

{-| A record argument whose `name` field is used both as a number and as a `String` is rejected with a TYPE MISMATCH.

In `k c`, `c.name + 1` needs `name` to be a number, while passing `c` to `h`, which computes `a.name ++ "s"`, needs it to be a `String`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two flexible records
-- CHECK: -- TYPE MISMATCH -

h a = a.name ++ "s"

k c =
    let
        z = c.name + 1
    in
    h c
