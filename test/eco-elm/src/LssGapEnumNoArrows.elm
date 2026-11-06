module LssGapEnumNoArrows exposing (main)
{-| A custom type whose constructors take no arguments can be matched by `case`:
`toInt Red` prints 1.

## eco

A lambda-set specialization (LSS) control: it separates "declaring a type"
from "the constructor's arrows". These constructors take no arguments, so their
constructor functions carry no arrows. If the loss is about zero here while
test/elm/src/LssGapCtorScale.elm loses positions, the cause is the synthesized
constructor arrow types.

-}
-- CHECK: enumNoArrows: 1
import Html exposing (text)
type Colour = Red | Green | Blue
toInt : Colour -> Int
toInt c =
    case c of
        Red -> 1
        Green -> 2
        Blue -> 3
main =
    let _ = Debug.log "enumNoArrows" (toInt Red) in text "hello"
