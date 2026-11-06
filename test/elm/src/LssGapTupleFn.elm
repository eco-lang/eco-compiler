module LssGapTupleFn exposing (main)
{-| A function stored in a tuple is taken out by destructuring and called.

`pair` is `( double, 7 )`, and `useTuple` binds `( f, x )` in a `let` and computes `f x`,
logging 14. -}
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
