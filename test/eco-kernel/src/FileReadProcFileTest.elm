module FileReadProcFileTest exposing (main)

{-| FILE-08 / decision D22 (plans/kernel-lib-bug-fixes.md): `Eco.File.readString`
sizes a file with `tellg` and reads exactly that many bytes. A procfs file
reports size 0, so `readString "/proc/self/status"` returns "" today. Node's
`fs.readFileSync` (the JS twin) and Haskell's `readFile` return the content;
D22 decided to read to EOF when a file is not regular or reports size 0.

This is the observable part of FILE-08's rewrite (the stale-errno half has
no deterministic trigger). After the fix the content starts with "Name:".
-}

-- LINUX-ONLY: procfs
-- CHECK: FileReadProcFileTest: True

import Eco.File as File
import Platform
import Task


type Msg
    = Done String


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , File.readString "/proc/self/status"
        |> Task.onError (\_ -> Task.succeed "<error>")
        |> Task.perform Done
    )


update : Msg -> () -> ( (), Cmd Msg )
update (Done s) m =
    let
        _ =
            Debug.log "FileReadProcFileTest length" (String.length s)

        _ =
            Debug.log "FileReadProcFileTest" (String.startsWith "Name:" s)
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
