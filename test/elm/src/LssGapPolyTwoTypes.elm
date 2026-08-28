module LssGapPolyTwoTypes exposing (main)

{-| LSS gap probe — ONE polymorphic annotated def instantiated at TWO types.

This is the shape §8.3.4's hypothesis is really about: a `Forall` annotation
whose solver variable is generalized. Instantiating at two types also forces the
signature to conduct rather than being inlined at a single site.
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
