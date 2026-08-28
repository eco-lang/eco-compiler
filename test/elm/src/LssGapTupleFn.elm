module LssGapTupleFn exposing (main)
{-| A function value in a TUPLE — the `TTuple`/`Tuple1` arm of the stamping
walk, a different container path from records. -}
-- CHECK: tupleFn: 14
import Html exposing (text)
double : Int -> Int
double n = n * 2
pair : ( Int -> Int, Int )
pair = ( double, 7 )
useTuple : ( Int -> Int, Int ) -> Int
useTuple p =
    let ( f, x ) = p in f x
main =
    let _ = Debug.log "tupleFn" (useTuple pair) in text "hello"
