module SpineStandalonePapTest exposing (main)

{-| Inner-arrow pin for S.10 arity-threaded standalone spine injection
(`plans/list-map-mlir-template.md` F-5C; `ECO_MONO_LSS_SPINE_ARITY=1`).

`SpinePapDispatchTest` covers LAMBDA spines. This one covers STANDALONE
members — a global and a constructor, each partially applied and then used as
a value. With the flag off, such a value's callback-position arrow is `LTop`;
with it on, the member id is injected through the first `declaredArity`
arrows, so the partial application still names a resolvable set.

The values must be identical in both modes: the flag changes which arrows
carry member ids, never what the program computes. That is the whole point of
the pin — the original unbounded-spine bug was a MISCOMPILE, not a wrong
census.

-}

-- CHECK: viaGlobalPap: [11, 12, 13]
-- CHECK: viaCtorPap: [3, 4, 5]
-- CHECK: viaThreeArity: [111, 112, 113]
-- CHECK: composed: [22, 24, 26]

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
        -- A partially applied GLOBAL as a callback: the residual arrow is the
        -- one spine injection has to reach.
        viaGlobalPap : List Int
        viaGlobalPap =
            List.map (addTwo 10) [ 1, 2, 3 ]

        -- A partially applied CONSTRUCTOR: `Pair 2` is arity-2 saturated to 1.
        viaCtorPap : List Int
        viaCtorPap =
            List.map (\n -> pairSum (Pair 2 n)) [ 1, 2, 3 ]

        -- Two arrows peeled off a three-arity global.
        viaThreeArity : List Int
        viaThreeArity =
            List.map (addThree 100 10) [ 1, 2, 3 ]

        -- A partial application flowing through composition, so the value
        -- reaches the callback position without ever being named.
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
