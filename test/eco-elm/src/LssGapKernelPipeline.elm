module LssGapKernelPipeline exposing (main)

{-| A JSON decoder that produces a partially applied constructor can be passed
to another function and finished there.

`decodePair` is `Json.Decode.map Pair` over field `"a"`, so it decodes to an
`Int -> Pair`. `consume` maps over that decoder to apply the function to 2,
then decodes `{"a":7}`, giving `Pair 7 2` and printing 9. Its `String`
argument is ignored.

## eco

A lambda-set specialization (LSS) probe from the coverage-levers work
(plans/lss-coverage-four-levers.md): where does payload-arrow transport stop for
kernel-backed combinators? `decodePair` is a definition whose annotation carries
a syntactic payload arrow and whose body computes the member through the kernel
`Json.Decode.map`; `consume` reads that payload one hop away, so it is covered
only if `decodePair`'s signature published the fact.

Read with `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1`, grep `^pos|`.

-}

-- CHECK: kernelPipeline: 9

import Html exposing (text)
import Json.Decode as D


type Pair
    = Pair Int Int


pairValue : Pair -> Int
pairValue (Pair a b) =
    a + b


decodePair : D.Decoder (Int -> Pair)
decodePair =
    D.map Pair (D.field "a" D.int)


consume : D.Decoder (Int -> Pair) -> String -> Int
consume dec _ =
    case D.decodeString (D.map (\f -> pairValue (f 2)) dec) "{\"a\":7}" of
        Ok n ->
            n

        Err _ ->
            0


main =
    let
        _ =
            Debug.log "kernelPipeline" (consume decodePair "unused")
    in
    text "hello"
