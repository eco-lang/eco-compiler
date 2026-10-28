module NestedUnboxLetDestructFloatTest exposing (main)

{-| A `let` destructure through two nested single-constructor wrappers of a
number-polymorphic value, `(Outer (Inner y)) = o` with `o = Outer (Inner 1)`,
where `y` is then used as a `Float`.

DEFAULT engine (solver): monomorphization types `y` as `MInt` (and `o` as
`Outer Int`) although `y + 0.5` is `Float` arithmetic, and the build crashes
in codegen: "Kernel signature mismatch for Elm_Kernel_Basics_add_Float:
existing (f64, f64 -> f64) vs new (i64, f64 -> f64)". New finding; no unit
test covers it. Pipeline-level: TestLogic/Monomorphize/NestedUnboxDestructTypeTest.elm.

EXPECTED TO FAIL until fixed.

-}

-- CHECK: y: 1.5

import Html exposing (text)


type Outer a
    = Outer (Inner a)


type Inner a
    = Inner a


main =
    let
        o =
            Outer (Inner 1)

        (Outer (Inner y)) =
            o

        _ =
            Debug.log "y" (y + 0.5)
    in
    text "done"
