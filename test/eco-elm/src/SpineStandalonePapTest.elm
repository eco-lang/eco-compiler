module SpineStandalonePapTest exposing (main)

{-| Functions passed to `List.map` as partial applications of top-level functions, a lambda building a custom type value, or a composition compute the expected results.

The test maps over `[ 1, 2, 3 ]` four times:

  - `viaGlobalPap` maps `addTwo 10`, a two-argument function given one argument.
  - `viaCtorPap` maps a lambda that builds `Pair 2 n` and sums it with
    `pairSum`.
  - `viaThreeArity` maps `addThree 100 10`, a three-argument function given two
    arguments.
  - `composed` maps `double << addTwo 10`, so the partial application is passed
    through function composition without being named.

## eco

Pins arity-threaded spine injection for standalone lambda-set members
(plans/list-map-mlir-template.md; flag `ECO_MONO_LSS_SPINE_ARITY=1`). The members
here are a global and a constructor, partially applied and used as values. With
the flag off such a value's callback-position arrow is `LTop`; with it on, the
member id is injected through the first `declaredArity` arrows so the partial
application still names a resolvable set.

The output must be identical in both modes: the original unbounded-spine bug was
a miscompile, not a wrong count.

-}

-- CHECK: viaGlobalPap: [11,12,13]
-- CHECK: viaCtorPap: [3,4,5]
-- CHECK: viaThreeArity: [111,112,113]
-- CHECK: composed: [22,24,26]

import Html exposing (text)


type Pair
    = Pair Int Int


addTwo : Int -> Int -> Int
addTwo a b =
    a + b


addThree : Int -> Int -> Int -> Int
addThree a b c =
    a + b + c


pairSum : Pair -> Int
pairSum (Pair a b) =
    a + b


double : Int -> Int
double n =
    n * 2


main : Html.Html msg
main =
    let
        viaGlobalPap : List Int
        viaGlobalPap =
            List.map (addTwo 10) [ 1, 2, 3 ]

        viaCtorPap : List Int
        viaCtorPap =
            List.map (\n -> pairSum (Pair 2 n)) [ 1, 2, 3 ]

        viaThreeArity : List Int
        viaThreeArity =
            List.map (addThree 100 10) [ 1, 2, 3 ]

        composed : List Int
        composed =
            List.map (double << addTwo 10) [ 1, 2, 3 ]

        _ =
            Debug.log "viaGlobalPap" viaGlobalPap

        _ =
            Debug.log "viaCtorPap" viaCtorPap

        _ =
            Debug.log "viaThreeArity" viaThreeArity

        _ =
            Debug.log "composed" composed
    in
    text "done"
