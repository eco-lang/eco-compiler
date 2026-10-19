module StreamTransformCapacityTest exposing (main)

{-| Capacities of custom transformations (plans/eco-system-library.md §3.5,
Phase 6 step 6.3).

  - readCapacity 0 is a rendezvous: a written value is only transformed once
    a reader waits, so the `write` completes after the read starts, and the
    transform's call counter shows it ran once per read.
  - A negative readCapacity is treated as 0 and a writeCapacity of 0 as 1
    (an `enqueue` is accepted at once).
  - `Send` may overfill the read buffer: one write produces three values
    although readCapacity is 1; the next write is transformed only once all
    three have been read.

-}

-- CHECK: rendezvous: mark,w1 ok | 0:a
-- CHECK: clamped: enqueue ok | 0:b
-- CHECK: overfill: x1,x2,mark,w2 ok,y1 | x3
-- EXIT: 0

import Stream
import Stream.Transformation
import StreamTestHelp exposing (describe, logEvent, sleep, spawnLogged)
import System
import Task exposing (Task)


counted : Int -> String -> Stream.Transformation.CustomAction Int String
counted n value =
    Stream.Transformation.Send { state = n + 1, send = [ String.fromInt n ++ ":" ++ value ] }


rendezvous : Task Stream.Error String
rendezvous =
    Task.map2 Tuple.pair StreamTestHelp.eventLog (Stream.Transformation.customWith counted { initialState = 0, readCapacity = 0, writeCapacity = 1 })
        |> Task.andThen
            (\( log, t ) ->
                spawnLogged log "w1" (Stream.write "a" (Stream.Transformation.writable t))
                    |> Task.andThen (\_ -> sleep)
                    |> Task.andThen (\_ -> logEvent log "mark")
                    |> Task.andThen (\_ -> Stream.read (Stream.Transformation.readable t))
                    |> Task.andThen
                        (\value ->
                            sleep
                                |> Task.andThen (\_ -> StreamTestHelp.finishLog log)
                                |> Task.map (\events -> String.join "," events ++ " | " ++ value)
                        )
            )


clamped : Task Stream.Error String
clamped =
    Stream.Transformation.customWith counted { initialState = 0, readCapacity = -5, writeCapacity = 0 }
        |> Task.andThen
            (\t ->
                describe (Stream.enqueue "b" (Stream.Transformation.writable t))
                    |> Task.andThen
                        (\enqueued ->
                            Stream.read (Stream.Transformation.readable t)
                                |> Task.map (\value -> "enqueue " ++ enqueued ++ " | " ++ value)
                        )
            )


triple : () -> String -> Stream.Transformation.CustomAction () String
triple state value =
    Stream.Transformation.Send { state = state, send = [ value ++ "1", value ++ "2", value ++ "3" ] }


overfill : Task Stream.Error String
overfill =
    Task.map2 Tuple.pair StreamTestHelp.eventLog (Stream.Transformation.customWith triple { initialState = (), readCapacity = 1, writeCapacity = 1 })
        |> Task.andThen
            (\( log, t ) ->
                let
                    r =
                        Stream.Transformation.readable t

                    readLogged =
                        Stream.read r |> Task.andThen (logEvent log)
                in
                Stream.write "x" (Stream.Transformation.writable t)
                    |> Task.andThen (\_ -> spawnLogged log "w2" (Stream.write "y" (Stream.Transformation.writable t)))
                    |> Task.andThen (\_ -> sleep)
                    |> Task.andThen (\_ -> readLogged)
                    |> Task.andThen (\_ -> readLogged)
                    |> Task.andThen (\_ -> logEvent log "mark")
                    |> Task.andThen (\_ -> Stream.read r)
                    |> Task.andThen
                        (\third ->
                            sleep
                                |> Task.andThen (\_ -> readLogged)
                                |> Task.andThen (\_ -> StreamTestHelp.finishLog log)
                                |> Task.map (\events -> String.join "," events ++ " | " ++ third)
                        )
            )


main : Platform.Program System.Environment () ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.sequence
                [ rendezvous |> Task.map (\r -> "rendezvous: " ++ r)
                , clamped |> Task.map (\r -> "clamped: " ++ r)
                , overfill |> Task.map (\r -> "overfill: " ++ r)
                ]
        )
