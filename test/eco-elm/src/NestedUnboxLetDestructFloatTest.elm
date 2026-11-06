module NestedUnboxLetDestructFloatTest exposing (main)

{-| A number literal wrapped in two nested single-constructor types,
`Outer (Inner 1)`, is destructured in a `let` with the pattern
`(Outer (Inner y))`, and `y` takes the type `Float` from its use in `y + 0.5`.

The literal `1` has type `number`, so nothing fixes it to `Int`; the program
logs `y: 1.5`.

## eco

Regression test for the default solver engine of the monomorphizer. It used to type `y` as
Int (and `o` as `Outer Int`), and codegen crashed with "Kernel signature mismatch for
Elm_Kernel_Basics_add_Float". The per-use root instances (`refineRootInstance` in
compiler/src/Compiler/Monomorphize/Solver/Translate.elm) only followed a constructor field whose
declared type is a bare type parameter, and `Outer`'s field is `Inner a`; they now match any field
type structurally. The monomorphizer-level test is
compiler/tests/Compiler/Monomorphize/Solver/NestedUnboxDestructTypeTest.elm.

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
