module ProcessRunHugeDurationTest exposing (main)

{-| A `ChildProcess.run` whose `runDuration` is longer than any timer can wait means no limit
(system-kernel-cpp/src/ChildProcess.elm `RunDuration`). Since the timer service maps a delay it
cannot represent to 1 ms (TIME-08), a run with `Milliseconds` beyond 2147483647 ms (Node's timer
range) used to have its child killed at once; now it runs to its end. The largest delay that is
still a limit, 2147483647 ms, is honoured as one and does not fire either.
-}

-- LINUX-ONLY: uses sh
-- CHECK: limit 2147483647: ok done
-- CHECK: limit 4000000000000: ok done
-- CHECK: limit 9007199254740991: ok done
-- EXIT: 0

import Bytes
import Bytes.Decode
import ChildProcess as P
import Stream
import System
import Task exposing (Task)


runWith : Int -> Task x String
runWith ms =
    P.run "sh"
        [ "-c", "sleep 0.2; printf done" ]
        { shell = P.NoShell
        , workingDirectory = P.InheritWorkingDirectory
        , environmentVariables = P.InheritEnvironmentVariables
        , maximumBytesWrittenToStreams = 0
        , runDuration = P.Milliseconds ms
        }
        |> Task.map
            (\r ->
                "ok "
                    ++ (Bytes.Decode.decode (Bytes.Decode.string (Bytes.width r.stdout)) r.stdout
                            |> Maybe.withDefault "?"
                       )
            )
        |> Task.onError
            (\err ->
                Task.succeed <|
                    case err of
                        P.InitError _ ->
                            "InitError"

                        P.ProgramError e ->
                            "ProgramError " ++ String.fromInt e.exitCode
            )
        |> Task.map (\s -> "limit " ++ String.fromInt ms ++ ": " ++ s)


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            [ 2147483647, 4000000000000, 9007199254740991 ]
                |> List.map (\ms -> runWith ms |> Task.andThen (\line -> Stream.logLine line env.stdout))
                |> Task.sequence
                |> Task.map (\_ -> ())
        )
