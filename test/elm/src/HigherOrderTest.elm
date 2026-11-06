module HigherOrderTest exposing (main)

{-| Simple higher-order functions apply their function argument the right number of times.

The test logs `apply double 5` (10), `apply square 5` (25) and
`twice double 5` (20).

-}

-- CHECK: apply1: 10
-- CHECK: apply2: 25
-- CHECK: twice1: 20

import Html exposing (text)


apply f x = f x
twice f x = f (f x)
double x = x * 2
square x = x * x


main =
    let
        _ = Debug.log "apply1" (apply double 5)
        _ = Debug.log "apply2" (apply square 5)
        _ = Debug.log "twice1" (twice double 5)
    in
    text "done"
