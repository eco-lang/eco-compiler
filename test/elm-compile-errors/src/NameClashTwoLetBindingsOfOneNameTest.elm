module NameClashTwoLetBindingsOfOneNameTest exposing (..)

{-| A `let` block that defines `y` twice is rejected with a NAME CLASH error.

-}

-- COMPILE-ERROR: NAME CLASH, two let bindings of one name
-- CHECK: -- NAME CLASH -

testValue =
    let
        y =
            1

        y =
            2
    in
    y
