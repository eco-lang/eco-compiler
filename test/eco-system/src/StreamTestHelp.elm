module StreamTestHelp exposing (describe, eventLog, finishLog, logEvent, program, sleep, spawnLogged)

{-| Shared helpers for the eco/system stream tests (not a test: no `main`).

Every test prints its observations to the program's real stdout through
`Stream.Log`, so the `-- CHECK:` patterns are matched against raw fd output.

Concurrent stream operations are observed through an event log: an identity
stream with a large buffer that spawned processes write labelled results into,
and that the test reads back, in order, at the end.

-}

import Process
import Stream
import Stream.Log
import System
import Task exposing (Task)


{-| A simple program that runs `run env` and prints every line it returns, or
`error: <reason>` if it fails.
-}
program : (System.Environment -> Task Stream.Error (List String)) -> System.SimpleProgram ()
program run =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (run env
                    |> Task.map (String.join "\n")
                    |> Task.onError (\err -> Task.succeed ("error: " ++ Stream.errorToString err))
                    |> Task.andThen (Stream.Log.line env.stdout)
                )
        )


{-| `ok` or `err <error>`, as a String.
-}
describe : Task Stream.Error a -> Task x String
describe task =
    task
        |> Task.map (\_ -> "ok")
        |> Task.onError (\err -> Task.succeed ("err " ++ Stream.errorToString err))


{-| An identity stream used as an ordered event log.
-}
eventLog : Task x (Stream.Transformation String String)
eventLog =
    Stream.identityTransformationWithOptions { readCapacity = 1000, writeCapacity = 1000 }


logEvent : Stream.Transformation String String -> String -> Task x ()
logEvent log event =
    Stream.enqueue event (Stream.writable log)
        |> Task.map (\_ -> ())
        |> Task.onError (\_ -> Task.succeed ())


{-| Close the log and read back every event, in order.
-}
finishLog : Stream.Transformation String String -> Task Stream.Error (List String)
finishLog log =
    Stream.closeWritable (Stream.writable log)
        |> Task.andThen
            (\_ ->
                Stream.readUntilClosed (\event acc -> Ok (event :: acc)) [] (Stream.readable log)
            )
        |> Task.map List.reverse


{-| Spawn `task` in its own process; when it finishes, log `<label> ok` or
`<label> err <error>`.
-}
spawnLogged : Stream.Transformation String String -> String -> Task Stream.Error a -> Task x ()
spawnLogged log label task =
    Process.spawn
        (describe task
            |> Task.andThen (\result -> logEvent log (label ++ " " ++ result))
        )
        |> Task.map (\_ -> ())


{-| Let spawned processes run until they park.
-}
sleep : Task x ()
sleep =
    Process.sleep 5
