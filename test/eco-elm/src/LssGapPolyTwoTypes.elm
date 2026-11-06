module LssGapPolyTwoTypes exposing (main)

{-| One polymorphic higher-order function, `twice : (a -> a) -> a -> a`, is used at two different types in the same program.

At `Int`, `twice double 5` gives 20. At `String`, `twice identity (dup "hi")` leaves `"hihi"`
unchanged, and its length, 4, is logged.

## eco

A lambda-set specialization (LSS) probe for the generalized-annotation
hypothesis of the provenance census (plans/lss-provenance-ratio-census.md; see
also test/eco-elm/src/LssGapPolyAnnotated.elm). Instantiating `twice` at two
types also forces its signature to carry the lambda set rather than being
inlined at a single site.

-}

-- CHECK: polyTwoTypes: 20
-- CHECK: polyTwoTypesStr: 4

import Html exposing (text)


twice : (a -> a) -> a -> a
twice f x =
    f (f x)


double : Int -> Int
double n =
    n * 2


dup : String -> String
dup s =
    s ++ s


main =
    let
        _ =
            Debug.log "polyTwoTypes" (twice double 5)

        _ =
            Debug.log "polyTwoTypesStr" (String.length (twice identity (dup "hi")))
    in
    text "hello"
