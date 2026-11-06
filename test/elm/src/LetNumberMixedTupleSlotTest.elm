module LetNumberMixedTupleSlotTest exposing (main)

{-| Two integer literals in a three-element tuple whose middle element is a
`String` are each used as a `Float`: matching `( 30, "x", 40 )` against
`( a, _, c )` and adding `round (a * 1.5)` to `round (c * 1.5)` logs 105.
-}

-- CHECK: mixedslot: 105

import Html exposing (text)


main =
    let
        result =
            case ( 30, "x", 40 ) of
                ( a, _, c ) ->
                    round (a * 1.5) + round (c * 1.5)

        _ =
            Debug.log "mixedslot" result
    in
    text "done"
