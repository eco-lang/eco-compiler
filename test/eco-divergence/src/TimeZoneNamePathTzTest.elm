module TimeZoneNamePathTzTest exposing (main)

{-| TIME-06 (plans/kernel-lib-bug-fixes.md): `Time.getZoneName` with a path-form `TZ`
(`:/usr/share/zoneinfo/Europe/Paris`). `getTimezoneName` (elm-kernel-cpp/src/time/TimeExports.cpp)
stripped the `:` and returned the rest, so eco answered `Name "/usr/share/zoneinfo/Europe/Paris"` before the fix.
Decision D30: `TZ` is a `Name` only when it is IANA-shaped or names a file under the zoneinfo
directory; for a path into that directory the name is the part after `zoneinfo/`, as the
`/etc/localtime` branch already does. Node gives `Name undefined` here, a documented divergence;
the JS runner does not run this suite.

-}

-- DIVERGENCE: eco reads a path TZ (:/usr/share/zoneinfo/...) for Time.getZoneName; node Intl reports Name undefined
-- ENV: TZ=:/usr/share/zoneinfo/Europe/Paris
-- LINUX-ONLY: TZ parsing and the zoneinfo layout are platform-specific
-- CHECK: zone: "Name Europe/Paris"

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
