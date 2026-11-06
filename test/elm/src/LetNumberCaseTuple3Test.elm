module LetNumberCaseTuple3Test exposing (main)

{-| A triple of number literals destructured by `case` twice, once summed as Ints and
once as Floats.

`a + b + c` leaves the literals at their default type `Int`, giving 60. Adding `1.0`
in the second sum makes them Floats, giving 61.0, which is logged rounded as 61.

-}

-- CHECK: case-tuple3-int: 60
-- CHECK: case-tuple3-float: 61

import Html exposing (text)


main =
    let
        intSum =
            case ( 10, 20, 30 ) of
                ( a, b, c ) ->
                    a + b + c

        floatSum =
            case ( 10, 20, 30 ) of
                ( a, b, c ) ->
                    a + b + c + 1.0

        _ =
            Debug.log "case-tuple3-int" intSum

        _ =
            Debug.log "case-tuple3-float" (round floatSum)
    in
    text "done"
