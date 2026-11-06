module TimeIssue16CustomZoneEraOrderTest exposing (main)

{-| `customZone` only works when its eras are listed from latest to earliest.

<https://github.com/elm/time/issues/16>

The documentation says "Human times will be based on the nearest `start`". With the eras listed
earliest first, `[ { start = 0, offset = 60 }, { start = 1000, offset = 120 } ]`, a time at minute
2000 must use the nearest start (1000, offset +2h): minute 2000 is 09:20 UTC on the second day,
so 11:20 local. Elm 0.19.1 (elm/time 1.0.0) takes the first era that started before the time, offset +1h, giving 10:20.

-}

-- CHECK: earliest first: (11,20)
-- CHECK: latest first: (11,20)

import Html exposing (text)
import Time


{-| Returns the local hour and minute in `zone` of the instant 2000 minutes after the epoch.
-}
hm : Time.Zone -> ( Int, Int )
hm zone =
    let
        t =
            Time.millisToPosix (2000 * 60000)
    in
    ( Time.toHour zone t, Time.toMinute zone t )


main =
    let
        _ =
            Debug.log "earliest first" (hm (Time.customZone 0 [ { start = 0, offset = 60 }, { start = 1000, offset = 120 } ]))

        _ =
            Debug.log "latest first" (hm (Time.customZone 0 [ { start = 1000, offset = 120 }, { start = 0, offset = 60 } ]))
    in
    text "done"
