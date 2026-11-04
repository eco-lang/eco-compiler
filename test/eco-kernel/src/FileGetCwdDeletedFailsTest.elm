module FileGetCwdDeletedFailsTest exposing (main)

{-| FILE-04 (plans/kernel-lib-bug-fixes.md): `Eco.File.getCwd` after the
working directory was removed. getcwd(3) fails with ENOENT, and the kernel
body fails the task with the IO error tuple ("could not get current working
directory"). Before decision D10 the API typed the task `Task Never`, so the
failure reached `Task.attempt` as an `Err` holding a value of type Never. D10
retyped `getCwd` to `Task IOError String`, so the program now gets
`FileNotFound`.
-}

-- LINUX-ONLY: getcwd ENOENT after rmdir of cwd
-- CHECK: FileGetCwdDeletedFailsTest: reached Err FileNotFound
-- CHECK-NOT: FileGetCwdDeletedFailsTest: reached Ok

import Eco.File as File
import Eco.IO.Error exposing (IOError(..))
import Platform
import Task exposing (Task)


dir : String
dir =
    "/tmp/eco-kernel-FileGetCwdDeletedFailsTest/cwd"


type Msg
    = Setup Bool
    | Done String


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , File.createDir True dir
        |> Task.andThen (\_ -> File.setCwd dir)
        |> Task.andThen (\_ -> File.removeDir dir)
        |> Task.attempt (\r -> Setup (r == Ok ()))
    )


update : Msg -> () -> ( (), Cmd Msg )
update msg m =
    case msg of
        Setup False ->
            let
                _ =
                    Debug.log "FileGetCwdDeletedFailsTest: setup failed" ()
            in
            ( m, Cmd.none )

        Setup True ->
            ( m
            , Task.attempt
                (\r ->
                    case r of
                        Ok s ->
                            Done ("Ok " ++ s)

                        Err (FileNotFound _) ->
                            Done "Err FileNotFound"

                        Err _ ->
                            Done "Err (another constructor)"
                )
                File.getCwd
            )

        Done how ->
            let
                _ =
                    Debug.log ("FileGetCwdDeletedFailsTest: reached " ++ how) ()
            in
            ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
