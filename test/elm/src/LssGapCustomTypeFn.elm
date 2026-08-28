module LssGapCustomTypeFn exposing (main)
{-| A function value inside a CUSTOM TYPE constructor — the `TType`/`App1` arm. -}
-- CHECK: customTypeFn: 14
import Html exposing (text)
type Box = Box (Int -> Int)
double : Int -> Int
double n = n * 2
useBox : Box -> Int -> Int
useBox (Box f) x = f x
main =
    let _ = Debug.log "customTypeFn" (useBox (Box double) 7) in text "hello"
