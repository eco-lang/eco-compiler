module NameClashTwoLetBindingsOfOneNameTest exposing (..)

{-| NAME CLASH: two let bindings of one name.

From `SourceIR.CanonicalizeFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: NAME CLASH, two let bindings of one name
-- CHECK: -- NAME CLASH -
-- CHECK: `y`

testValue =
    let
        y =
            1

        y =
            2
    in
    y
