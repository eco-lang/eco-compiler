module StreamCancelReadableTest exposing (main)

{-| `cancelReadable` (plans/eco-system-library.md §3.5): the buffer is dropped,
later reads get `Closed`, and the writer — both the one already waiting and any
later one — gets `Cancelled` with the reason. Cancelling while a read is parked
fails with `Locked`.
-}

-- CHECK: cancel while parked: err Locked
-- CHECK: cancel: ok
-- CHECK: read after cancel: err Closed
-- CHECK: write after cancel: err Cancelled: stop reading
-- CHECK: events: pending err Cancelled: stop reading
-- EXIT: 0

import Process
import Stream
import StreamTestHelp exposing (sleep, spawnLogged)
import System
import Task


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            -- A parked read holds the read lock.
            Stream.identityTransformation
                |> Task.andThen
                    (\t ->
                        Process.spawn (Stream.read (Stream.readable t))
                            |> Task.andThen (\_ -> sleep)
                            |> Task.andThen (\_ -> StreamTestHelp.describe (Stream.cancelReadable "x" (Stream.readable t)))
                    )
                |> Task.andThen
                    (\lockedResult ->
                        Task.map2 Tuple.pair StreamTestHelp.eventLog (Stream.identityTransformationWithOptions { readCapacity = 1, writeCapacity = 1 })
                            |> Task.andThen
                                (\( log, t ) ->
                                    Stream.write 1 (Stream.writable t)
                                        |> Task.andThen (\_ -> spawnLogged log "pending" (Stream.write 2 (Stream.writable t)))
                                        |> Task.andThen (\_ -> sleep)
                                        |> Task.andThen (\_ -> StreamTestHelp.describe (Stream.cancelReadable "stop reading" (Stream.readable t)))
                                        |> Task.andThen
                                            (\cancelResult ->
                                                Task.map2 Tuple.pair
                                                    (StreamTestHelp.describe (Stream.read (Stream.readable t)))
                                                    (StreamTestHelp.describe (Stream.write 3 (Stream.writable t)))
                                                    |> Task.andThen
                                                        (\( readResult, writeResult ) ->
                                                            sleep
                                                                |> Task.andThen (\_ -> StreamTestHelp.finishLog log)
                                                                |> Task.map
                                                                    (\events ->
                                                                        [ "cancel while parked: " ++ lockedResult
                                                                        , "cancel: " ++ cancelResult
                                                                        , "read after cancel: " ++ readResult
                                                                        , "write after cancel: " ++ writeResult
                                                                        , "events: " ++ String.join "," events
                                                                        ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )

