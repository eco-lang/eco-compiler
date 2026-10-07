module StreamCancelWritableTest exposing (main)

{-| `cancelWritable` (plans/eco-system-library.md §3.5): a reader parked on the
stream, and every later reader, gets `Cancelled` with the reason; later writes
fail the same way. Buffered values are dropped.
-}

-- CHECK: cancel: ok
-- CHECK: events: parked err Cancelled: abort!
-- CHECK: read after cancel: err Cancelled: abort!
-- CHECK: write after cancel: err Cancelled: abort!
-- CHECK: buffered dropped: err Cancelled: gone
-- EXIT: 0

import Stream
import StreamTestHelp exposing (sleep, spawnLogged)
import System
import Task


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.map2 Tuple.pair StreamTestHelp.eventLog (Stream.identityTransformationWithOptions { readCapacity = 2, writeCapacity = 2 })
                |> Task.andThen
                    (\( log, t ) ->
                        spawnLogged log "parked" (Stream.read (Stream.readable t))
                            |> Task.andThen (\_ -> sleep)
                            |> Task.andThen (\_ -> StreamTestHelp.describe (Stream.cancelWritable "abort!" (Stream.writable t)))
                            |> Task.andThen
                                (\cancelResult ->
                                    Task.map2 Tuple.pair
                                        (StreamTestHelp.describe (Stream.read (Stream.readable t)))
                                        (StreamTestHelp.describe (Stream.write "late" (Stream.writable t)))
                                        |> Task.andThen
                                            (\( readResult, writeResult ) ->
                                                sleep
                                                    |> Task.andThen (\_ -> StreamTestHelp.finishLog log)
                                                    |> Task.map
                                                        (\events ->
                                                            [ "cancel: " ++ cancelResult
                                                            , "events: " ++ String.join "," events
                                                            , "read after cancel: " ++ readResult
                                                            , "write after cancel: " ++ writeResult
                                                            ]
                                                        )
                                            )
                                )
                    )
                |> Task.andThen
                    (\lines ->
                        Stream.identityTransformationWithOptions { readCapacity = 2, writeCapacity = 2 }
                            |> Task.andThen
                                (\t ->
                                    Stream.write "buffered" (Stream.writable t)
                                        |> Task.andThen (Stream.cancelWritable "gone")
                                        |> Task.andThen (\_ -> StreamTestHelp.describe (Stream.read (Stream.readable t)))
                                        |> Task.map (\r -> lines ++ [ "buffered dropped: " ++ r ])
                                )
                    )
        )
