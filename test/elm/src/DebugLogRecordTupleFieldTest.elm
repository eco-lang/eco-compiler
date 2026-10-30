module DebugLogRecordTupleFieldTest exposing (main)

{-| A `Debug.log` call used directly as a record field or tuple element whose
type is unboxable (Int, Float). The `Debug.log` kernel call yields an
`!eco.value`, but `Expr.generateRecordCreate` and `Expr.generateTupleCreate`
pass an element the layout stores unboxed through as it is, so the
`eco.construct.record` / `eco.construct.tuple2` op declares an i64/f64 slot for
an `!eco.value` operand and the module fails to verify (CGEN\_026): "slot\_kinds[0]
= 1 does not match operand type '!eco.value'". The same values built as a
custom-type constructor's arguments or as list items compile fine.

The record is logged through its fields: Debug.toString of a record lists the
fields in layout order on eco and by name in Elm, a formatting difference this
test is not about.

-}

-- CHECK: first: 1
-- CHECK: second: 2.5
-- CHECK: pair: (1,2.5)
-- CHECK: x: 3
-- CHECK: y: 0.5
-- CHECK: point: (3,0.5,"p")

import Html exposing (text)


pair : Int -> ( Int, Float )
pair n =
    ( Debug.log "first" n, Debug.log "second" 2.5 )


point : Int -> { x : Int, y : Float, label : String }
point n =
    { x = Debug.log "x" n, y = Debug.log "y" 0.5, label = "p" }


main =
    let
        _ =
            Debug.log "pair" (pair 1)

        p =
            point 3

        _ =
            Debug.log "point" ( p.x, p.y, p.label )
    in
    text "done"
