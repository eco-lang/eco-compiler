module TimePosixTest exposing (main)

{-| `Time.posixToMillis` gives back the milliseconds a `Time.Posix` was made from with `Time.millisToPosix`.
-}

-- CHECK: roundtrip: 1000

import Html exposing (text)
import Time

main =
    let
        posix = Time.millisToPosix 1000
        _ = Debug.log "roundtrip" (Time.posixToMillis posix)
    in
    text "done"
