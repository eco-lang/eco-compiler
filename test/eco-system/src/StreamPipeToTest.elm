module StreamPipeToTest exposing (main)

{-| `pipeTo` (plans/eco-system-library.md §3.5, Phase 6 step 6.3): the task
completes once the source has closed and the destination has been closed;
the destination's reader sees every value and then `Closed`; with a
capacity-1 destination the pipe follows the reader (backpressure): it
completes once the destination has accepted the last value, i.e. when the
reader has taken all but the buffered one.
-}

-- CHECK: buffered: ok | 1,2,3,4,5 closed
-- CHECK: backpressure: r1,pipe ok,r2,r3 | Closed
-- EXIT: 0

import Stream
import StreamCodecHelp exposing (readAll)
import StreamTestHelp exposing (describe, logEvent, sleep, spawnLogged)
import System
import Task exposing (Task)


buffered : Task Stream.Error String
buffered =
    Task.map2 Tuple.pair (Stream.fromList [ 1, 2, 3, 4, 5 ]) (Stream.identityTransformationWithOptions { readCapacity = 10, writeCapacity = 10 })
        |> Task.andThen
            (\( source, dst ) ->
                describe (Stream.pipeTo (Stream.writable dst) source)
                    |> Task.andThen
                        (\piped ->
                            readAll (Stream.readable dst)
                                |> Task.map (\values -> piped ++ " | " ++ String.join "," (List.map String.fromInt values) ++ " closed")
                        )
            )


backpressure : Task Stream.Error String
backpressure =
    Task.map3 (\log source dst -> ( log, source, dst ))
        StreamTestHelp.eventLog
        (Stream.fromList [ "a", "b", "c" ])
        Stream.identityTransformation
        |> Task.andThen
            (\( log, source, dst ) ->
                let
                    r =
                        Stream.readable dst

                    readLogged label =
                        Stream.read r |> Task.andThen (\_ -> sleep) |> Task.andThen (\_ -> logEvent log label)
                in
                spawnLogged log "pipe" (Stream.pipeTo (Stream.writable dst) source)
                    |> Task.andThen (\_ -> sleep)
                    |> Task.andThen (\_ -> readLogged "r1")
                    |> Task.andThen (\_ -> readLogged "r2")
                    |> Task.andThen (\_ -> readLogged "r3")
                    |> Task.andThen (\_ -> sleep)
                    |> Task.andThen (\_ -> Stream.read r |> Task.map (\_ -> "value") |> Task.onError (\e -> Task.succeed (Stream.errorToString e)))
                    |> Task.andThen
                        (\last ->
                            StreamTestHelp.finishLog log
                                |> Task.map (\events -> String.join "," events ++ " | " ++ last)
                        )
            )


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.map2 (\a b -> [ "buffered: " ++ a, "backpressure: " ++ b ]) buffered backpressure
        )
