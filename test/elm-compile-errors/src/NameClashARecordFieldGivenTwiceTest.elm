module NameClashARecordFieldGivenTwiceTest exposing (..)

{-| NAME CLASH: a record field given twice.

From `SourceIR.CanonicalizeFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: NAME CLASH, a record field given twice
-- CHECK: -- NAME CLASH -
-- CHECK: multiple `a` fields

testValue =
    { a = 1, a = 2 }
