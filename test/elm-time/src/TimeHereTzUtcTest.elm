module TimeHereTzUtcTest exposing (main)

{-| `Time.here` honours the `TZ` environment variable: with `TZ=UTC0` it gives a zone with no offset, so the Unix epoch reads as 00:00.

The program asks for `Time.here` and logs the hour and minute of
`Time.millisToPosix 0` in the zone it receives. Any other offset from UTC
would change the hour or the minute.

Among what is not tested: daylight saving time, and any zone other than UTC.

-}

-- ENV: TZ=UTC0
-- CHECK: here: "hour: 0"
-- CHECK: here: "minute: 0"

import Platform
import Task
import Time


{-| The local zone returned by `Time.here`.
-}
type Msg
    = Here Time.Zone


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform Here Time.here )
        , update =
            \(Here zone) m ->
                let
                    _ =
                        Debug.log "here" ("hour: " ++ String.fromInt (Time.toHour zone (Time.millisToPosix 0)))

                    _ =
                        Debug.log "here" ("minute: " ++ String.fromInt (Time.toMinute zone (Time.millisToPosix 0)))
                in
                ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
