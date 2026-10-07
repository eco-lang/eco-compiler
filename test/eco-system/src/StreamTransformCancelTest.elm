module StreamTransformCancelTest exposing (main)

{-| A custom `Cancel` (plans/eco-system-library.md §3.5, WHATWG
controller.error): the triggering write succeeds; buffered values are
dropped; a parked reader, later reads and later writes all fail with
`Cancelled` and the reason; a write queued behind the cancelling one fails
too.
-}

-- CHECK: events: boom ok,queued err Cancelled: bad input
-- CHECK: read: err Cancelled: bad input
-- CHECK: write after: err Cancelled: bad input
-- CHECK: parked: err Cancelled: bad input
-- EXIT: 0

import Stream
import StreamTestHelp exposing (describe, sleep, spawnLogged)
import System
import Task exposing (Task)


action : () -> String -> Stream.CustomTransformationAction () String
action state value =
    if value == "boom" then
        Stream.Cancel "bad input"

    else
        Stream.Send { state = state, send = [ value ] }


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.map2 Tuple.pair StreamTestHelp.eventLog (Stream.customTransformationWithOptions action { initialState = (), readCapacity = 1, writeCapacity = 2 })
                |> Task.andThen
                    (\( log, t ) ->
                        let
                            w =
                                Stream.writable t

                            r =
                                Stream.readable t
                        in
                        -- "keep" fills readQ (capacity 1); "boom" waits in writeQ;
                        -- "queued" waits behind it. The read takes "keep", which
                        -- lets "boom" through: it cancels the pair.
                        Stream.write "keep" w
                            |> Task.andThen (\_ -> spawnLogged log "boom" (Stream.write "boom" w))
                            |> Task.andThen (\_ -> sleep)
                            |> Task.andThen (\_ -> spawnLogged log "queued" (Stream.write "queued" w))
                            |> Task.andThen (\_ -> sleep)
                            |> Task.andThen (\_ -> Stream.read r)
                            |> Task.andThen (\_ -> sleep)
                            |> Task.andThen
                                (\_ ->
                                    Task.map2 Tuple.pair
                                        (describe (Stream.read r))
                                        (describe (Stream.write "late" w))
                                )
                            |> Task.andThen
                                (\( readResult, writeResult ) ->
                                    StreamTestHelp.finishLog log
                                        |> Task.map
                                            (\events ->
                                                [ "events: " ++ String.join "," events
                                                , "read: " ++ readResult
                                                , "write after: " ++ writeResult
                                                ]
                                            )
                                )
                    )
                |> Task.andThen
                    (\lines ->
                        -- A reader parked when the cancel happens.
                        Stream.customTransformationWithOptions action { initialState = (), readCapacity = 0, writeCapacity = 1 }
                            |> Task.andThen
                                (\t ->
                                    Task.map2 Tuple.pair StreamTestHelp.eventLog (Task.succeed t)
                                )
                            |> Task.andThen
                                (\( log, t ) ->
                                    spawnLogged log "parked" (Stream.read (Stream.readable t))
                                        |> Task.andThen (\_ -> sleep)
                                        |> Task.andThen (\_ -> Stream.enqueue "boom" (Stream.writable t))
                                        |> Task.andThen (\_ -> sleep)
                                        |> Task.andThen (\_ -> StreamTestHelp.finishLog log)
                                        |> Task.map (\events -> lines ++ [ String.join "," (List.map (String.replace "parked " "parked: ") events) ])
                                )
                    )
        )
