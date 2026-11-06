module LambdaPatternArgTest exposing (main)

{-| Checks anonymous functions whose parameters are tuple, record and wildcard patterns.

`swap` destructures a pair, `getX` destructures a record with field `x`, and
`mixed` takes a variable, a pair pattern and a wildcard and returns the pair's
first element.

-}

-- CHECK: swap: (2,1)
-- CHECK: getX: 42
-- CHECK: mixed: "b"

import Html exposing (text)


main =
    let
        swap =
            \( x, y ) -> ( y, x )

        getX =
            \{ x } -> x

        mixed =
            \a ( b, c ) _ -> b

        _ =
            Debug.log "swap" (swap ( 1, 2 ))

        _ =
            Debug.log "getX" (getX { x = 42 })

        _ =
            Debug.log "mixed" (mixed 1 ( "b", 2 ) 3)
    in
    text "done"
