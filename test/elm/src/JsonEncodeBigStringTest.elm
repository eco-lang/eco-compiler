module JsonEncodeBigStringTest exposing (main)

{-| Json.Encode.string must handle every native string representation.
Strings above the leaf size classes (built here via String.repeat) are
stored as ropes / large-block strings; Elm\_Kernel\_Json\_wrap used to
recognize only flat Tag\_String leaves and rendered everything else as
JSON null. 5000 chars + 2 quotes = 5002.
-}

-- CHECK: JsonEncodeBigStringTest: 5002

import Html exposing (text)
import Json.Encode as E


main =
    let
        encoded =
            E.encode 0 (E.string (String.repeat 5000 "x"))

        _ =
            Debug.log "JsonEncodeBigStringTest" (String.length encoded)
    in
    text "ok"
