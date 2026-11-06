module TypeMismatchNumberAndCompappendListEntriesTest exposing (..)

{-| A list literal whose entries are `a + 1` and a value `c` that is both appended (`b ++ b`) and compared (`c < c`) is rejected with a TYPE MISMATCH error.

All entries of a list share one type. `c` must be a `compappend` (appendable and comparable) and `a + 1` a `number`, and no type is both.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number and compappend list entries
-- CHECK: -- TYPE MISMATCH -

f a b =
    let
        c = b ++ b
    in
    if c < c then [ a + 1, c ] else []
