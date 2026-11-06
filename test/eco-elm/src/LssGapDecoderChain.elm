module LssGapDecoderChain exposing (main)

{-| An applicative chain over a custom type wrapping a function builds a
constructor value one field at a time.

`D e a` wraps an `Int -> Result e a`. `pureD Pair` stores the two-argument
constructor `Pair`, and each `applyD` supplies one more argument, so after
`applyD (dInt 7)` and then `applyD (dInt 2)` the result is `Ok (Pair 7 2)`;
`pairValue` prints 7 + 2 = 9.

## eco

A lambda-set specialization (LSS) probe for the constructor-arrow identity work
(plans/lss-ctor-arrow-identity.md): a minimal replica of the applicative decode
chain, once the largest source of unresolved positions in the self-compile.
`pureD Pair` stores a partially applied constructor inside a container, carries
it across items and applies it at the end, so each step is one transport link:
the argument injection at `pureD Pair`, the tie between the stored field arrow
and the container's type argument, the crossing into `applyD`'s and `runD`'s
items, and the readback at the consumer.

Read with `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1`, grep `^pos|`; the
interesting rows are `pureD|/a0...` and every `.../c1...` row.

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
