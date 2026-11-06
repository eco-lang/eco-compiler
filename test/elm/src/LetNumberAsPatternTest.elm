module LetNumberAsPatternTest exposing (main)

{-| A tuple of number literals matched with an `as` pattern, where one part and the
whole tuple are both used.

In `case ( 30, 40 ) of (( a, _ ) as whole)`, `a * 1.5` makes the elements Floats, and
`Tuple.first whole + Tuple.second whole` reads both through the alias. The result is
`round 45.0 + round 70.0 = 115`.

-}

-- CHECK: aspat: 115

import Html exposing (text)


main =
    let
        result =
            case ( 30, 40 ) of
                (( a, _ ) as whole) ->
                    round (a * 1.5) + round (Tuple.first whole + Tuple.second whole)

        _ =
            Debug.log "aspat" result
    in
    text "done"
