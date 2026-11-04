module FileAppDataDirNoHomeVarsTest exposing (main)

{-| ECO-NEW-1 (plans/kernel-lib-bug-fixes.md): `Eco.File.appDataDir` with
neither HOME nor ECO_HOME set, as the compiler's cache-home lookup
(`Builder.Stuff.getElmHome`) runs it in a sandbox.

`appDataDir` was a `Task Never String` whose kernel body failed with a plain
String when HOME was unset: a `Task.perform` of it never delivered its
message. Decision D10 typed it `Task IOError String`, and the kernel now falls
back to the passwd entry's home directory (as elm's Haskell
`getAppUserDataDirectory` and Node's `os.userInfo()` do), failing with
`FileNotFound` only when there is no home at all. So the message arrives, and
on a host where the uid has a passwd entry the result ends with `/.ecotest`.
Only the suffix is checked: the home directory differs between hosts.
(FileAppDataDirNoHomeTest, FILE-04, unsets HOME alone.)
-}

-- LINUX-ONLY: the POSIX branch (macOS appends /Library/Application Support/<name>; Windows reads APPDATA)
-- UNSETENV: HOME ECO_HOME
-- CHECK: FileAppDataDirNoHomeVarsTest started
-- CHECK: FileAppDataDirNoHomeVarsTest: dir ends with /.ecotest: True

import Eco.File as File
import Eco.IO.Error as IOErr exposing (IOError)
import Platform
import Task


type Msg
    = GotDir (Result IOError String)


init : () -> ( (), Cmd Msg )
init _ =
    let
        _ =
            Debug.log "FileAppDataDirNoHomeVarsTest started" ()
    in
    ( (), Task.attempt GotDir (File.appDataDir "ecotest") )


update : Msg -> () -> ( (), Cmd Msg )
update (GotDir r) m =
    let
        _ =
            case r of
                Ok dir ->
                    let
                        _ =
                            Debug.log "FileAppDataDirNoHomeVarsTest result" dir
                    in
                    Debug.log "FileAppDataDirNoHomeVarsTest: dir ends with /.ecotest"
                        (String.endsWith "/.ecotest" dir && dir /= "/.ecotest")

                Err e ->
                    let
                        _ =
                            Debug.log "FileAppDataDirNoHomeVarsTest error" (IOErr.toString e)
                    in
                    Debug.log "FileAppDataDirNoHomeVarsTest: dir ends with /.ecotest" False
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
