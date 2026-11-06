module LetNumberWildcardSlotTest exposing (main)

{-| The first and last integer literals of a three-element tuple are used as
`Float`s while the middle one is matched by a wildcard: matching
`( 30, 40, 50 )` against `( a, _, c )` and adding `round (a * 1.5)` to
`round (c * 1.5)` logs 120.
-}

-- CHECK: wildslot: 120

import Html exposing (text)


main =
    let
        result =
            case ( 30, 40, 50 ) of
                ( a, _, c ) ->
                    round (a * 1.5) + round (c * 1.5)

        _ =
            Debug.log "wildslot" result
    in
    text "done"
