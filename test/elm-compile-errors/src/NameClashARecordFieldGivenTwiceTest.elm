module NameClashARecordFieldGivenTwiceTest exposing (..)

{-| A record literal that gives the same field twice, `{ a = 1, a = 2 }`, is rejected with a NAME CLASH error.

-}

-- COMPILE-ERROR: NAME CLASH, a record field given twice
-- CHECK: -- NAME CLASH -

testValue =
    { a = 1, a = 2 }
