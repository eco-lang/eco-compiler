module LetNumberNestedTupleTest exposing (main)

{-| Integer literals in the inner tuple of a nested tuple are used as `Float`s while
the outer one stays an `Int`: matching `( ( 30, 40 ), 50 )` against
`( ( a, b ), c )` and computing `round (a * 1.5) + round (b * 1.5) + c`
logs 155.
-}

-- CHECK: nesttup: 155

import Html exposing (text)


main =
    let
        result =
            case ( ( 30, 40 ), 50 ) of
                ( ( a, b ), c ) ->
                    round (a * 1.5) + round (b * 1.5) + c

        _ =
            Debug.log "nesttup" result
    in
    text "done"
