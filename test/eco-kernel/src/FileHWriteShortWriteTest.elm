module FileHWriteShortWriteTest exposing (main)

{-| FILE-07 (plans/kernel-lib-bug-fixes.md), the short-write half:
`Eco.File.hWriteString` makes one `write` call and ignores a short count. With
RLIMIT_FSIZE at 1 MiB (SIGXFSZ ignored), a 2 MiB string written to a fresh file
is cut at 1 MiB by the first `write`, which returns 1048576; the call reports
`Ok`. After the fix the write loop's second call fails with EFBIG, reported as
`OtherIOError`.

The limit covers every file this process writes, the captured stdout file
included, which stays far below 1 MiB here.
-}

-- LINUX-ONLY: RLIMIT_FSIZE short write
-- RLIMIT-FSIZE: 1048576
-- CHECK: FileHWriteShortWriteTest: Err OtherIOError

import Eco.File as File
import Eco.IO.Error exposing (IOError(..))
import Platform
import Task


dir : String
dir =
    "/tmp/eco-kernel-FileHWriteShortWriteTest"


type Msg
    = Done String
    | Removed


init : () -> ( (), Cmd Msg )
init _ =
    let
        task =
            File.createDir True dir
                |> Task.andThen (\_ -> File.open (dir ++ "/f") File.WriteMode)
                |> Task.andThen
                    (\h ->
                        File.hWriteString h (String.repeat (2 * 1024 * 1024) "x")
                            |> Task.andThen (\_ -> File.close h)
                    )
    in
    ( ()
    , Task.attempt
        (\r ->
            case r of
                Ok _ ->
                    Done "Ok"

                Err (OtherIOError _) ->
                    Done "Err OtherIOError"

                Err _ ->
                    Done "Err other"
        )
        task
    )


update : Msg -> () -> ( (), Cmd Msg )
update msg m =
    case msg of
        Done s ->
            let
                _ =
                    Debug.log ("FileHWriteShortWriteTest: " ++ s) ()
            in
            ( m, Task.attempt (\_ -> Removed) (File.removeFile (dir ++ "/f")) )

        Removed ->
            ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
