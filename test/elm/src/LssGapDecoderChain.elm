module LssGapDecoderChain exposing (main)

{-| P0.b probe for plans/lss-ctor-arrow-identity.md §8.2 — a minimal replica of
the shape that holds 56.5 % of all remaining `var` positions in the
self-compile: the APPLICATIVE DECODE CHAIN.

`pure Ctor |> apply d1 |> apply d2` stores a partially-applied constructor
inside a container (`D e (Int -> Pair)`), carries it across items, and applies
it at the end. Every rung of the chain is a distinct link of the transport
model (§0): the arg injection at `pureD Pair` (L-in), the tie between the
stored field arrow and the container's type argument (L-mirror), the crossing
into `applyD`'s and `runD`'s own items (L-across), and the readback at the
consumer (L-out).

Read with `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1`, grep `^pos|`;
the interesting rows are `pureD|/a0…` (is the ctor's spine covered at the arg
position?) and every `…/c1…` row (the container's type argument — the mass).

-}

-- CHECK: decoderChain: 9

import Html exposing (text)


type D e a
    = D (Int -> Result e a)


type Pair
    = Pair Int Int


pureD : a -> D e a
pureD a =
    D (\_ -> Ok a)


applyD : D e a -> D e (a -> b) -> D e b
applyD (D da) (D df) =
    D
        (\i ->
            case ( df i, da i ) of
                ( Ok f, Ok a ) ->
                    Ok (f a)

                ( Err e, _ ) ->
                    Err e

                ( _, Err e ) ->
                    Err e
        )


dInt : Int -> D e Int
dInt n =
    D (\_ -> Ok n)


runD : D e a -> Result e a
runD (D f) =
    f 0


pairValue : Pair -> Int
pairValue (Pair a b) =
    a + b


main =
    let
        _ =
            Debug.log "decoderChain"
                (case runD (applyD (dInt 2) (applyD (dInt 7) (pureD Pair))) of
                    Ok p ->
                        pairValue p

                    Err () ->
                        -1
                )
    in
    text "h"
