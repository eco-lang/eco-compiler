module LssGapRecordNoFn exposing (main)
{-| A record alias with only `Int` fields is read through field access and the fields summed.

It is the counterpart to `LssGapRecordField` with no function in the record: `2 + 7` logs 9.

## eco

A lambda-set specialization (LSS) control for
test/eco-elm/src/LssGapRecordField.elm: the same record shape with no function
field. If the arrow-stamping walk loses arrows here too, records are not the
cause.

-}
-- CHECK: recordNoFn: 9
import Html exposing (text)
type alias Nums = { a : Int, b : Int }
nums : Nums
nums = { a = 2, b = 7 }
useNums : Nums -> Int
useNums o = o.a + o.b
main =
    let _ = Debug.log "recordNoFn" (useNums nums) in text "hello"
