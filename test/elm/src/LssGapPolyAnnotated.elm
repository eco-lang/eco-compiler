module LssGapPolyAnnotated exposing (main)

{-| LSS gap probe A — an ANNOTATED POLYMORPHIC higher-order def.

Hypothesis under test (plans/lss-provenance-ratio-census.md §8.3.4): a
polymorphic annotation's solver variable is generalized and carries no `Fun1`
structure, so `SolverRoots.stampArrowRoots` fails at the ROOT and every arrow in
the annotation loses its provenance at once.

If that holds, `applyTwice`'s `f` position should be less resolved here than in
the otherwise-identical monomorphic probe `LssGapMonoAnnotated`.
-}

-- CHECK: polyAnnotated: 20

import Html exposing (text)


applyTwice : (a -> a) -> a -> a
applyTwice f x =
    f (f x)


double : Int -> Int
double n =
    n * 2


main =
    let
        _ =
            Debug.log "polyAnnotated" (applyTwice double 5)
    in
    text "hello"
