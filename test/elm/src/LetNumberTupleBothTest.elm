module LetNumberTupleBothTest exposing (main)

{-| Both integer-literal elements of a let-bound pair are used as `Float`s:
`round (Tuple.first p * 1.5) + round (Tuple.second p * 1.5)` with
`p = ( 30, 40 )` logs 105.
-}

-- CHECK: tupboth: 105

import Html exposing (text)


main =
    let
        p =
            ( 30, 40 )

        result =
            round (Tuple.first p * 1.5) + round (Tuple.second p * 1.5)

        _ =
            Debug.log "tupboth" result
    in
    text "done"
