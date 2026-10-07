module ProcessTestHelp exposing (bytesToString, describeRun, noShell, simpleRun)

{-| Shared helpers for the eco/system process tests (not a test: no `main`).
Every test prints its observations to the program's real stdout through
`Stream.Log`, so the `-- CHECK:` patterns are matched against raw fd output.
-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Stream.Log
import System
import System.Process as P
import Task exposing (Task)


bytesToString : Bytes -> String
bytesToString bytes =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width bytes)) bytes
        |> Maybe.withDefault "<invalid utf-8>"


{-| `defaultRunOptions` without a shell. -}
noShell : P.RunOptions
noShell =
    let
        d =
            P.defaultRunOptions
    in
    { d | shell = P.NoShell }


{-| A one-line description of a run's outcome; newlines are shown as `|`. -}
describeRun : Task P.FailedRun P.SuccessfulRun -> Task x String
describeRun task =
    task
        |> Task.map
            (\r ->
                "ok stdout=" ++ clean (bytesToString r.stdout) ++ " stderr=" ++ clean (bytesToString r.stderr)
            )
        |> Task.onError
            (\err ->
                Task.succeed <|
                    case err of
                        P.InitError e ->
                            "InitError " ++ e.errorCode ++ " program=" ++ e.program ++ " args=" ++ String.join "," e.arguments

                        P.ProgramError e ->
                            "ProgramError "
                                ++ String.fromInt e.exitCode
                                ++ " stdout="
                                ++ clean (bytesToString e.stdout)
                                ++ " stderr="
                                ++ clean (bytesToString e.stderr)
            )


{-| Newlines shown as `|`. The empty string is returned as is: `String.replace` on "" hits a
runtime assertion (`String.join sep [ "" ]` allocates a zero-length ASCII string).
-}
clean : String -> String
clean s =
    if s == "" then
        ""

    else
        String.replace "\n" "|" s


{-| A simple program printing one line per labelled task. -}
simpleRun : List ( String, Task Never String ) -> System.SimpleProgram ()
simpleRun steps =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (steps
                    |> List.map (\( label, t ) -> Task.map (\s -> label ++ ": " ++ s) t)
                    |> Task.sequence
                    |> Task.map (String.join "\n")
                    |> Task.andThen (Stream.Log.line env.stdout)
                )
        )
