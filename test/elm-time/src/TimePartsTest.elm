module TimePartsTest exposing (main)

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
