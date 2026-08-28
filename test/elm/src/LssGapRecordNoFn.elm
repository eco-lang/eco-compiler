module LssGapRecordNoFn exposing (main)
{-| CONTROL for LssGapRecordField: same record shape, NO function field. If the
stamping walk loses arrows here too, records are not the cause. -}
-- CHECK: recordNoFn: 9
import Html exposing (text)
type alias Nums = { a : Int, b : Int }
nums : Nums
nums = { a = 2, b = 7 }
useNums : Nums -> Int
useNums o = o.a + o.b
main =
    let _ = Debug.log "recordNoFn" (useNums nums) in text "hello"
