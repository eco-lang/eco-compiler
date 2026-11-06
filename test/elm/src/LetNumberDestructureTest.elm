module LetNumberDestructureTest exposing (main)

{-| Two `number` literals bound by a tuple pattern in a `let` are both used as
`Float`s.

`( a, b ) = ( 30, 40 )` binds two independently typed `number` values.
`round (a * 1.5) + round (b * 1.5)` is 45 + 60, so the test logs 105.

-}

-- CHECK: destructure: 105

import Html exposing (text)


main =
    let
        ( a, b ) =
            ( 30, 40 )

        result =
            round (a * 1.5) + round (b * 1.5)

        _ =
            Debug.log "destructure" result
    in
    text "done"
