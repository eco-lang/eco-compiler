module NameClashTwoArgumentsOfOneNameTest exposing (..)

{-| A function whose two arguments share one name, `pick a a`, is rejected with a NAME CLASH error.

-}

-- COMPILE-ERROR: NAME CLASH, two arguments of one name
-- CHECK: -- NAME CLASH -

pick a a =
    a


testValue =
    pick 1 2
