module LssGapNoDecls exposing (main)
{-| NEGATIVE control: declares no types at all. Must sit exactly on the 122/218
background, which is what licenses reading the other probes' deltas. -}
-- CHECK: noDecls: 14
import Html exposing (text)
double : Int -> Int
double n = n * 2
main =
    let _ = Debug.log "noDecls" (double 7) in text "hello"
