module TimeZoneNamePosixTzTest exposing (main)

{-| TIME-06 (plans/kernel-lib-bug-fixes.md): `Time.getZoneName` with a POSIX-rule `TZ`.
Before the fix `getTimezoneName` (elm-kernel-cpp/src/time/TimeExports.cpp) returned any non-empty `TZ` as the zone
name, so eco answered `Name "CET-1CEST,M3.5.0,M10.5.0/3"`, which is not a zone name. Decision D30:
`TZ` is a `Name` only when it is IANA-shaped (or names a file under the zoneinfo directory), else
the `Offset` fallback, here the CET/CEST offset of the moment (60 or 120 minutes). Node gives
`Name "UTC"` (ICU cannot resolve the rule), a documented divergence; the JS runner does not run
this suite.

-}

-- ENV: TZ=CET-1CEST,M3.5.0,M10.5.0/3
-- LINUX-ONLY: TZ parsing and the zoneinfo layout are platform-specific
-- CHECK: zone: "{{Offset (60|120)}}"

import Platform
import Task
import Time


type Msg
    = Got Time.ZoneName


show : Time.ZoneName -> String
show z =
    case z of
        Time.Name s ->
            "Name " ++ s

        Time.Offset n ->
            "Offset " ++ String.fromInt n


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform Got Time.getZoneName )
        , update =
            \(Got z) m ->
                let
                    _ =
                        Debug.log "zone" (show z)
                in
                ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
