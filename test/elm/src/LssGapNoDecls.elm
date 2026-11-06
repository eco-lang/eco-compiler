module LssGapNoDecls exposing (main)
{-| A program with no type declarations calls one annotated top-level function.

`double 7` logs 14. -}
-- CHECK: noDecls: 14
import Html exposing (text)
double : Int -> Int
double n = n * 2
main =
    let _ = Debug.log "noDecls" (double 7) in text "hello"
