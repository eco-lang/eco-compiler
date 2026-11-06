module TimeIssue7ZoneTransitionStartTest exposing (main)

{-| A zone transition does not take effect at its own start minute.

<https://github.com/elm/time/issues/7>

With `customZone 0 [ { start = 120, offset = 60 } ]` (from 02:00 UTC the offset is +01:00), the
instant 02:00 UTC is 03:00 local time. Elm 0.19.1 (elm/time 1.0.0) looks for an era whose start is
`<` the time instead of `<=`, so it still uses offset 0 and gives 02:00.

-}

-- CHECK: at start: (3,0)
-- CHECK: one minute later: (3,1)

import Html exposing (text)
import Time


zone : Time.Zone
zone =
    Time.customZone 0 [ { start = 120, offset = 60 } ]


{-| Returns the local hour and minute in `zone` of the instant `minutes` after the epoch.
-}
hm : Int -> ( Int, Int )
hm minutes =
    let
        t =
            Time.millisToPosix (minutes * 60000)
    in
    ( Time.toHour zone t, Time.toMinute zone t )


main =
    let
        _ =
            Debug.log "at start" (hm 120)

        _ =
            Debug.log "one minute later" (hm 121)
    in
    text "done"
