module NameClashTwoArgumentsOfOneNameTest exposing (..)

{-| NAME CLASH: two arguments of one name.

From `SourceIR.CanonicalizeFailsCases` (`duplicateCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: NAME CLASH, two arguments of one name
-- CHECK: -- NAME CLASH -

pick a a =
    a


testValue =
    pick 1 2
