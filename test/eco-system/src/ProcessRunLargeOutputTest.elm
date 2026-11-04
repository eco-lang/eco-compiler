module ProcessRunLargeOutputTest exposing (main)

{-| PROC-07 (plans/kernel-lib-bug-fixes.md, group 07): a `ChildProcess.run` whose child writes
more than a pipe buffer must still complete. On Windows `startCollector`
(system-kernel-cpp/src/eco-system/ChildProcess/ChildProcess.cpp) started no collector and dropped
the pipe read ends without closing them, so the child blocked in its write once the buffer was
full; with the 20 s limit below the run then ended killed with no output (`bytes: 0`), and each
run leaked two CRT fds. Fixed by inspection with a Windows collector (blocking reads on two
threads). On POSIX the collector reads both pipes, so the test passes there: it is a regression
guard for the collector, and checks PROC-07 only on a Windows host (not run here; Windows fixes
may stay unverified, per project policy).
-}

-- CHECK: bytes: 200000 stderr: 4 result: ok
-- EXIT: 0

import Bytes
import ChildProcess as P
import Stream
import System exposing (Platform(..))
import Task


command : Platform -> ( String, List String )
command platform =
    case platform of
        Win32 ->
            ( "powershell"
            , [ "-NoProfile", "-Command", "[Console]::Out.Write('x' * 200000); [Console]::Error.Write('err' + [char]10)" ]
            )

        _ ->
            ( "sh", [ "-c", "head -c 200000 /dev/zero; echo err >&2" ] )


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            let
                ( program, args ) =
                    command env.platform
            in
            P.run program
                args
                { shell = P.NoShell
                , workingDirectory = P.InheritWorkingDirectory
                , environmentVariables = P.InheritEnvironmentVariables
                , maximumBytesWrittenToStreams = 0
                , runDuration = P.Milliseconds 20000
                }
                |> Task.map
                    (\r ->
                        "bytes: "
                            ++ String.fromInt (Bytes.width r.stdout)
                            ++ " stderr: "
                            ++ String.fromInt (Bytes.width r.stderr)
                            ++ " result: ok"
                    )
                |> Task.onError
                    (\err ->
                        Task.succeed <|
                            case err of
                                P.InitError _ ->
                                    "bytes: 0 result: InitError"

                                P.ProgramError e ->
                                    "bytes: "
                                        ++ String.fromInt (Bytes.width e.stdout)
                                        ++ " stderr: "
                                        ++ String.fromInt (Bytes.width e.stderr)
                                        ++ " result: ProgramError "
                                        ++ String.fromInt e.exitCode
                    )
                |> Task.andThen (\line -> Stream.logLine line env.stdout)
        )
