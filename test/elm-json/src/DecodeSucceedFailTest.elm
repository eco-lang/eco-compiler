module DecodeSucceedFailTest exposing (main)

{-| `Json.Decode.succeed 99` produces `99` whatever the input; here the input is `null`.
-}

-- CHECK: succeed1: Ok 99

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "succeed1" (Decode.decodeString (Decode.succeed 99) "null")
    in
    text "done"
