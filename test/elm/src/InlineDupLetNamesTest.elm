module InlineDupLetNamesTest exposing (main)

{-| A function whose body does a `case` on a tuple of its arguments gives the right result when one call to it is passed as an argument to another.

`helper (helper 1 2) 3`: the inner call takes the `( x, y )` branch and gives
3, and the outer call then gives 3 + 3 = 6.

-}

-- CHECK: InlineDupLetNamesTest: 6

import Html exposing (text)


helper : Int -> Int -> Int
helper a b =
    case ( a, b ) of
        ( 0, 0 ) ->
            1

        ( x, y ) ->
            x + y


main =
    let
        _ =
            Debug.log "InlineDupLetNamesTest" (helper (helper 1 2) 3)
    in
    text "ok"
