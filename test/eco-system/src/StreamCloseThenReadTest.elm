module StreamCloseThenReadTest exposing (main)

{-| Closing the writable side (plans/eco-system-library.md §3.5): buffered
values can still be read, then reads fail with `Closed`, every time. A reader
parked on an empty stream is woken with `Closed` by the close.
-}

-- CHECK: buffered: a,b
-- CHECK: after drain: err Closed
-- CHECK: again: err Closed
-- CHECK: events: parked err Closed,closed
-- EXIT: 0

import Stream
import Stream.Transformation
import StreamTestHelp exposing (logEvent, sleep, spawnLogged)
import System
import Task


main : Platform.Program System.Environment () ()
main =
    StreamTestHelp.program
        (\_ ->
            Stream.Transformation.identityWith { readCapacity = 4, writeCapacity = 4 }
                |> Task.andThen
                    (\t ->
                        Stream.write "a" (Stream.Transformation.writable t)
                            |> Task.andThen (Stream.write "b")
                            |> Task.andThen Stream.closeWritable
                            |> Task.andThen (\_ -> Task.map2 (\x y -> x ++ "," ++ y) (Stream.read (Stream.Transformation.readable t)) (Stream.read (Stream.Transformation.readable t)))
                            |> Task.andThen
                                (\buffered ->
                                    Task.map2 Tuple.pair
                                        (StreamTestHelp.describe (Stream.read (Stream.Transformation.readable t)))
                                        (StreamTestHelp.describe (Stream.read (Stream.Transformation.readable t)))
                                        |> Task.map (\( d1, d2 ) -> [ "buffered: " ++ buffered, "after drain: " ++ d1, "again: " ++ d2 ])
                                )
                    )
                |> Task.andThen
                    (\lines ->
                        Task.map2 Tuple.pair StreamTestHelp.eventLog Stream.Transformation.identity
                            |> Task.andThen
                                (\( log, t ) ->
                                    spawnLogged log "parked" (Stream.read (Stream.Transformation.readable t))
                                        |> Task.andThen (\_ -> sleep)
                                        |> Task.andThen (\_ -> Stream.closeWritable (Stream.Transformation.writable t))
                                        |> Task.andThen (\_ -> sleep)
                                        |> Task.andThen (\_ -> logEvent log "closed")
                                        |> Task.andThen (\_ -> StreamTestHelp.finishLog log)
                                        |> Task.map (\events -> lines ++ [ "events: " ++ String.join "," events ])
                                )
                    )
        )
