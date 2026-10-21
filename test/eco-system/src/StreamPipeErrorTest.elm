module StreamPipeErrorTest exposing (main)

{-| Error propagation through pipes (plans/eco-system-library.md §3.5, WHATWG
pipeTo defaults; Phase 6 step 6.3):

  - the source errors (its writable is cancelled) → the destination is
    aborted with the same reason and `pipeTo` fails with it;
  - the destination's readable is cancelled → the source is cancelled with
    the reason (writers into it fail) and `pipeTo` fails;
  - an error in the middle of a pipeThrough chain reaches the end of it;
  - piping into a closed writable cancels the source.

-}

-- CHECK: source error: pipe err Cancelled: boom | dst err Cancelled: boom
-- CHECK: dest error: pipe err Cancelled: stop | src write err Cancelled: stop
-- CHECK: chain error: err Cancelled: mid
-- CHECK: closed dest: err Closed | src read err Closed
-- EXIT: 0

import Stream
import Stream.Transformation
import StreamCodecHelp exposing (readAll)
import StreamTestHelp exposing (describe, logEvent, sleep, spawnLogged)
import System
import Task exposing (Task)


sourceError : Task Stream.Error String
sourceError =
    Task.map3 (\log src dst -> ( log, src, dst )) StreamTestHelp.eventLog Stream.Transformation.identity Stream.Transformation.identity
        |> Task.andThen
            (\( log, src, dst ) ->
                spawnLogged log "pipe" (Stream.pipeTo (Stream.Transformation.writable dst) (Stream.Transformation.readable src))
                    |> Task.andThen (\_ -> sleep)
                    |> Task.andThen (\_ -> Stream.cancelWritable "boom" (Stream.Transformation.writable src))
                    |> Task.andThen (\_ -> sleep)
                    |> Task.andThen (\_ -> describe (Stream.read (Stream.Transformation.readable dst)))
                    |> Task.andThen
                        (\dstRead ->
                            StreamTestHelp.finishLog log
                                |> Task.map (\events -> String.join "," events ++ " | dst " ++ dstRead)
                        )
            )


destError : Task Stream.Error String
destError =
    Task.map3 (\log src dst -> ( log, src, dst )) StreamTestHelp.eventLog Stream.Transformation.identity Stream.Transformation.identity
        |> Task.andThen
            (\( log, src, dst ) ->
                spawnLogged log "pipe" (Stream.pipeTo (Stream.Transformation.writable dst) (Stream.Transformation.readable src))
                    |> Task.andThen (\_ -> sleep)
                    |> Task.andThen (\_ -> Stream.cancelReadable "stop" (Stream.Transformation.readable dst))
                    |> Task.andThen (\_ -> sleep)
                    |> Task.andThen (\_ -> describe (Stream.write "late" (Stream.Transformation.writable src)))
                    |> Task.andThen
                        (\srcWrite ->
                            StreamTestHelp.finishLog log
                                |> Task.map (\events -> String.join "," events ++ " | src write " ++ srcWrite)
                        )
            )


chainError : Task Stream.Error String
chainError =
    Task.map2 Tuple.pair Stream.Transformation.identity Stream.Transformation.identity
        |> Task.andThen
            (\( first, middle ) ->
                Stream.pipeThrough middle (Stream.Transformation.readable first)
                    |> Task.andThen (Stream.awaitAndPipeThrough Stream.Transformation.identity)
                    |> Task.andThen
                        (\end ->
                            Stream.write "v" (Stream.Transformation.writable first)
                                |> Task.andThen (\_ -> Stream.cancelWritable "mid" (Stream.Transformation.writable first))
                                |> Task.andThen (\_ -> describe (readAll end))
                        )
            )


closedDest : Task Stream.Error String
closedDest =
    Task.map2 Tuple.pair (Stream.fromList [ "a" ]) Stream.Transformation.identity
        |> Task.andThen
            (\( src, dst ) ->
                Stream.closeWritable (Stream.Transformation.writable dst)
                    |> Task.andThen (\_ -> describe (Stream.pipeTo (Stream.Transformation.writable dst) src))
                    |> Task.andThen
                        (\piped ->
                            describe (Stream.read src)
                                |> Task.map (\r -> piped ++ " | src read " ++ r)
                        )
            )


main : Platform.Program System.Environment () ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.sequence
                [ sourceError |> Task.map (\r -> "source error: " ++ r)
                , destError |> Task.map (\r -> "dest error: " ++ r)
                , chainError |> Task.map (\r -> "chain error: " ++ r)
                , closedDest |> Task.map (\r -> "closed dest: " ++ r)
                ]
        )
