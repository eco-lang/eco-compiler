module LssGapRecordFnNoAlias exposing (main)
{-| Isolates the ALIAS from the record: a function field in an INLINE record
type, no `type alias`. -}
-- CHECK: recordFnNoAlias: 14
import Html exposing (text)
double : Int -> Int
double n = n * 2
useIt : { transform : Int -> Int } -> Int -> Int
useIt o x = o.transform x
main =
    let _ = Debug.log "recordFnNoAlias" (useIt { transform = double } 7) in text "hello"
