module FileFindExecutableSkipsDirTest exposing (main)

{-| FILE-09 (plans/kernel-lib-bug-fixes.md): `Eco.File.findExecutable` accepts
any path that passes `access(X_OK)`, and a searchable directory passes. With a
directory named `sh` in the first PATH entry, today the result is
`Just ".../shadow/sh"`. Haskell's `findExecutable` (and the fix: also require a
regular file) skips it and finds the real `sh` in /usr/bin or /bin.
-}

-- LINUX-ONLY: POSIX access(X_OK)
-- ENV: PATH=/tmp/eco-kernel-FileFindExecutableSkipsDirTest/shadow:/usr/bin:/bin
-- CHECK: FileFindExecutableSkipsDirTest: True

import Eco.File as File
import Platform
import Task


type Msg
    = Done (Result () (Maybe String))


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , File.createDir True "/tmp/eco-kernel-FileFindExecutableSkipsDirTest/shadow/sh"
        |> Task.mapError (\_ -> ())
        |> Task.andThen (\_ -> File.findExecutable "sh" |> Task.mapError never)
        |> Task.attempt Done
    )


update : Msg -> () -> ( (), Cmd Msg )
update (Done r) m =
    let
        ok =
            case r of
                Ok (Just p) ->
                    not (String.contains "/shadow/" p) && String.endsWith "/sh" p

                _ ->
                    False

        _ =
            Debug.log "FileFindExecutableSkipsDirTest result" r

        _ =
            Debug.log "FileFindExecutableSkipsDirTest" ok
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
