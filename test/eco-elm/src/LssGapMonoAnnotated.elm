module LssGapMonoAnnotated exposing (main)

{-| A higher-order function with a monomorphic annotation, `(Int -> Int) -> Int -> Int`, applies its function argument twice.

`applyTwice double 5` doubles 5 twice, so the program logs 20. `LssGapPolyAnnotated` is the
same program with `applyTwice` annotated polymorphically.

## eco

A lambda-set specialization (LSS) probe for a hypothesis from the provenance
census (plans/lss-provenance-ratio-census.md): a polymorphic annotation's solver
variable is generalized and carries no function structure, so `stampArrowRoots`
in compiler/src/Compiler/Type/SolverRoots.elm fails at the root and every arrow
in the annotation loses its provenance. If that holds, `applyTwice`'s `f`
position is less resolved in test/eco-elm/src/LssGapPolyAnnotated.elm than in
test/eco-elm/src/LssGapMonoAnnotated.elm.

-}

-- CHECK: monoAnnotated: 20

import Html exposing (text)


applyTwice : (Int -> Int) -> Int -> Int
applyTwice f x =
    f (f x)


double : Int -> Int
double n =
    n * 2


main =
    let
        _ =
            Debug.log "monoAnnotated" (applyTwice double 5)
    in
    text "hello"
