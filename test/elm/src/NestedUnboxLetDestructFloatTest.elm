module NestedUnboxLetDestructFloatTest exposing (main)

{-| A `let` destructure through two nested single-constructor wrappers of a
number-polymorphic value, `(Outer (Inner y)) = o` with `o = Outer (Inner 1)`,
where `y` is then used as a `Float`.

DEFAULT engine (solver): monomorphization used to type `y` as `MInt` (and
`o` as `Outer Int`) although `y + 0.5` is `Float` arithmetic, and the build
crashed in codegen: "Kernel signature mismatch for Elm_Kernel_Basics_add_Float:
existing (f64, f64 -> f64) vs new (i64, f64 -> f64)". The solver's per-use
root instances (`refineRootInstance`) only followed a constructor field whose
declared type is a bare type parameter; `Outer`'s field is `Inner a`. They now
match any field type structurally. Pipeline-level:
TestLogic/Monomorphize/NestedUnboxDestructTypeTest.elm.

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
