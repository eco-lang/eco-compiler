module LssGapEnumNoArrows exposing (main)
{-| Discriminates "declaring a type" from "the constructor's ARROWS". This type
declares constructors that take NO arguments, so its constructor functions carry
no arrows. If the loss is ~0 here while LssGapCtorScale loses 20, the cause is
specifically the synthesized constructor ARROW types. -}
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
