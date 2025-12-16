module CustomTypeBasicTest exposing (main)

{-| Test basic custom type creation.
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
