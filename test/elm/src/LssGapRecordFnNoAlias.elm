module LssGapRecordFnNoAlias exposing (main)
{-| A function stored in a field of an unaliased record type is called through that field.

`useIt` takes `{ transform : Int -> Int }` written inline in its annotation, and calling it with
`{ transform = double }` and 7 logs 14. -}
-- CHECK: recordFnNoAlias: 14
import Html exposing (text)
double : Int -> Int
double n = n * 2
useIt : { transform : Int -> Int } -> Int -> Int
useIt o x = o.transform x
main =
    let _ = Debug.log "recordFnNoAlias" (useIt { transform = double } 7) in text "hello"
