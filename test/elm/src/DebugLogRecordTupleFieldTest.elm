module DebugLogRecordTupleFieldTest exposing (main)

{-| A `Debug.log` call can be used directly as an `Int` or `Float` component of a
tuple or field of a record, and the value it returns is stored there.

`pair` builds `( Debug.log "first" n, Debug.log "second" 2.5 )`, and `point`
builds a record whose `x` and `y` fields are `Debug.log` calls. The test checks
the lines each `Debug.log` prints and the tuple or record contents logged
afterwards. The record is logged as a tuple of its fields, so the check does not
depend on how `Debug.toString` formats a record.

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
