module NumberGenericAppTuple exposing (main)

{-| A number literal passed through a generic function, here `Tuple.first`
applied to `( 30, "x" )`, keeps the type `number`, so the `let`-bound result
can be used in `Float` arithmetic: `round (1.5 * n)` logs 45.
-}

-- CHECK: numgenapp: 45

import Html exposing (text)


main =
    let
        n =
            Tuple.first ( 30, "x" )

        _ =
            Debug.log "numgenapp" (round (1.5 * n))
    in
    text "done"
