module TimeHereTzUtcTest exposing (main)

{-| TIME-05 (plans/kernel-lib-bug-fixes.md): `Time.here` under `TZ=UTC0` gives the UTC zone, so the
epoch is 00:00. On Linux and macOS `getLocalTimezoneOffset` (elm-kernel-cpp/src/time/TimeExports.cpp)
reads `tm_gmtoff`, which honours `TZ`, so this passes there. The bug is Windows-only: that branch
returns the CRT's `_timezone` without ever calling `_tzset`, so it holds the CRT default (28800,
UTC-8, hour 16) and ignores daylight saving time; the fix calls `_tzset` and uses `localtime_s`. The
DST half cannot be pinned without a date-dependent expectation (verify by hand on Windows in a DST
zone). Elm on node with `TZ=UTC0` prints the same two lines. Left unmarked: it passes on Linux, and
Windows is low priority.

-}

-- ENV: TZ=UTC0
-- CHECK: here: "hour: 0"
-- CHECK: here: "minute: 0"

import Platform
import Task
import Time


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
