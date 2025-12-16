module HigherOrderTest exposing (main)

{-| Test higher-order functions.
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
