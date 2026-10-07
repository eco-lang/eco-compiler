module StreamBackpressureTest exposing (main)

{-| Backpressure on identity(1,1) (plans/eco-system-library.md §3.5, Phase 3
step 3.6): w1 succeeds at once (its value moves to the read buffer); w2 is
accepted but pending until a read makes room; w3 waits for room holding the
write lock; w4 fails with `Locked`. Each read releases exactly one writer.
-}

-- CHECK: w1: ok
-- CHECK: w4: err Locked
-- CHECK: events: mark1,w2 ok,mark2,w3 ok,mark3
-- CHECK: reads: 1,2,3
-- EXIT: 0

import Stream
import StreamTestHelp exposing (logEvent, sleep, spawnLogged)
import System
import Task


ints : List Int -> String
ints values =
    String.join "," (List.map String.fromInt values)


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.map2 Tuple.pair StreamTestHelp.eventLog (Stream.identityTransformationWithOptions { readCapacity = 1, writeCapacity = 1 })
                |> Task.andThen
                    (\( log, t ) ->
                        let
                            w =
                                Stream.writable t

                            r =
                                Stream.readable t
                        in
                        StreamTestHelp.describe (Stream.write 1 w)
                            |> Task.andThen
                                (\w1 ->
                                    spawnLogged log "w2" (Stream.write 2 w)
                                        |> Task.andThen (\_ -> sleep)
                                        |> Task.andThen (\_ -> spawnLogged log "w3" (Stream.write 3 w))
                                        |> Task.andThen (\_ -> sleep)
                                        |> Task.andThen (\_ -> StreamTestHelp.describe (Stream.write 4 w))
                                        |> Task.andThen
                                            (\w4 ->
                                                logEvent log "mark1"
                                                    |> Task.andThen (\_ -> Stream.read r)
                                                    |> Task.andThen
                                                        (\a ->
                                                            sleep
                                                                |> Task.andThen (\_ -> logEvent log "mark2")
                                                                |> Task.andThen (\_ -> Stream.read r)
                                                                |> Task.andThen
                                                                    (\b ->
                                                                        sleep
                                                                            |> Task.andThen (\_ -> logEvent log "mark3")
                                                                            |> Task.andThen (\_ -> Stream.read r)
                                                                            |> Task.map (\c -> [ a, b, c ])
                                                                    )
                                                        )
                                                    |> Task.andThen
                                                        (\reads ->
                                                            StreamTestHelp.finishLog log
                                                                |> Task.map
                                                                    (\events ->
                                                                        [ "w1: " ++ w1
                                                                        , "w4: " ++ w4
                                                                        , "events: " ++ String.join "," events
                                                                        , "reads: " ++ ints reads
                                                                        ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
