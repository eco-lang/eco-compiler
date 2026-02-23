module TimePosixTest exposing (main)

-- CHECK: roundtrip: 1000

import Html exposing (text)
import Time

main =
    let
        posix = Time.millisToPosix 1000
        _ = Debug.log "roundtrip" (Time.posixToMillis posix)
    in
    text "done"
