module FileTouchErrorClassTest exposing (main)

{-| FILE-06 (plans/kernel-lib-bug-fixes.md): `Eco.File.touch` ignored the
failure of its `open(O_CREAT)` and reported only the error of the following
`last_write_time`. In /sys the create fails with EACCES even as root (sysfs has
no create op; EROFS when /sys is read-only), the file is then missing, and the
time update fails with ENOENT, so the caller saw `FileNotFound` instead of the
real cause. /sys is used rather than a chmod-ed directory so the test also
works as root. (/proc does not show it: procfs fails the lookup itself with
ENOENT, so there the open's error is ENOENT too.)

Before the fix: `Err FileNotFound` → "wrong". After the fix: `PermissionDenied`
or `OtherIOError` (the saved open errno) → "ok".
-}

-- LINUX-ONLY: sysfs has no create op
-- CHECK: FileTouchErrorClassTest: ok

import Eco.File as File
import Eco.IO.Error exposing (IOError(..))
import Platform
import Task


type Msg
    = Done String


classify : Result IOError () -> String
classify r =
    case r of
        Ok _ ->
            "created"

        Err (FileNotFound _) ->
            "wrong"

        Err _ ->
            "ok"


init : () -> ( (), Cmd Msg )
init _ =
    ( (), Task.attempt (classify >> Done) (File.touch "/sys/eco-kernel-touch-test") )


update : Msg -> () -> ( (), Cmd Msg )
update (Done s) m =
    let
        _ =
            Debug.log ("FileTouchErrorClassTest: " ++ s) ()
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
