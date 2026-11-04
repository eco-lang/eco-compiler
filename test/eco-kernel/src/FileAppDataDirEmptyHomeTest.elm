module FileAppDataDirEmptyHomeTest exposing (main)

{-| FILE-11 (plans/kernel-lib-bug-fixes.md): `Eco.File.appDataDir` when HOME is set but empty.
The fix falls back to the passwd entry's home directory (getpwuid_r, as
Node's `os.userInfo()` does for the JS twin), so the result is
`<pw_dir>/.ecotest`. With no home at all the task fails with `FileNotFound`:
decision D10 typed `appDataDir` `Task IOError String`.

Before the fix an empty HOME was accepted and the result was "/.ecotest" (False).
(On a host whose uid has no passwd entry the task fails, and the test logs False.)
-}

-- LINUX-ONLY: the POSIX branch (macOS appends /Library/Application Support/<name>)
-- ENV: HOME=
-- CHECK: FileAppDataDirEmptyHomeTest: True

import Eco.File as File
import Platform
import Task


type Msg
    = Done Bool String


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , Task.attempt
        (\r ->
            case r of
                Ok s ->
                    Done (String.endsWith "/.ecotest" s && s /= "/.ecotest") ("Ok " ++ s)

                Err _ ->
                    Done False "Err"
        )
        (File.appDataDir "ecotest")
    )


update : Msg -> () -> ( (), Cmd Msg )
update (Done ok how) m =
    let
        _ =
            Debug.log ("FileAppDataDirEmptyHomeTest result " ++ how) ()

        _ =
            Debug.log "FileAppDataDirEmptyHomeTest" ok
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
