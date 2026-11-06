module CustomTypeBasicTest exposing (main)

{-| `Debug.log` prints each constructor of a custom type with no arguments by its
name.

The test logs `Red`, `Green` and `Blue` of the type `Color`.

-}

-- CHECK: color1: Red
-- CHECK: color2: Green
-- CHECK: color3: Blue

import Html exposing (text)


type Color
    = Red
    | Green
    | Blue


main =
    let
        _ = Debug.log "color1" Red
        _ = Debug.log "color2" Green
        _ = Debug.log "color3" Blue
    in
    text "done"
