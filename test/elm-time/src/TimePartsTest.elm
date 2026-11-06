module TimePartsTest exposing (main)

{-| `Time.toHour`, `Time.toMinute` and `Time.toSecond` in `Time.utc` give 0, 0 and 0 for the Unix epoch.
-}

-- CHECK: hour: 0
-- CHECK: minute: 0
-- CHECK: second: 0

import Html exposing (text)
import Time

main =
    let
        posix = Time.millisToPosix 0
        _ = Debug.log "hour" (Time.toHour Time.utc posix)
        _ = Debug.log "minute" (Time.toMinute Time.utc posix)
        _ = Debug.log "second" (Time.toSecond Time.utc posix)
    in
    text "done"
