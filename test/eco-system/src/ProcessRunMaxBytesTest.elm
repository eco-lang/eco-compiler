module ProcessRunMaxBytesTest exposing (main)

{-| `maximumBytesWrittenToStreams` (plans/eco-system-library.md Phase 5 step
5.4, E.4): a child that writes more is killed and the run fails with
ProgramError -1, holding the output truncated at the limit. Exactly the limit
is fine.
-}

-- CHECK: overflow: ProgramError -1 stdout-bytes=1000
-- CHECK: stderr-overflow: ProgramError -1 stdout-bytes=0 stderr-bytes=10
-- CHECK: exact: ok stdout-bytes=5
-- EXIT: 0

import Bytes
import ProcessTestHelp exposing (noShell, simpleRun)
import System.Process as P
import Task exposing (Task)


sizes : Task P.FailedRun P.SuccessfulRun -> Task Never String
sizes task =
    task
        |> Task.map (\r -> "ok stdout-bytes=" ++ String.fromInt (Bytes.width r.stdout))
        |> Task.onError
            (\err ->
                Task.succeed <|
                    case err of
                        P.InitError e ->
                            "InitError " ++ e.errorCode

                        P.ProgramError e ->
                            "ProgramError "
                                ++ String.fromInt e.exitCode
                                ++ " stdout-bytes="
                                ++ String.fromInt (Bytes.width e.stdout)
                                ++ " stderr-bytes="
                                ++ String.fromInt (Bytes.width e.stderr)
            )


main =
    simpleRun
        [ ( "overflow", sizes (P.run "yes" [] { noShell | maximumBytesWrittenToStreams = 1000 }) )
        , ( "stderr-overflow"
          , sizes (P.run "sh" [ "-c", "yes >&2" ] { noShell | maximumBytesWrittenToStreams = 10 })
          )
        , ( "exact", sizes (P.run "printf" [ "12345" ] { noShell | maximumBytesWrittenToStreams = 5 }) )
        ]
