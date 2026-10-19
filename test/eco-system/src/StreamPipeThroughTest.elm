module StreamPipeThroughTest exposing (main)

{-| `pipeThrough` / `awaitAndPipeThrough` (plans/eco-system-library.md §3.5,
Phase 6 step 6.3): a chain identity → custom → identity delivers every value
in order and closes at the end; a chain with a readCapacity-0 custom stage
still flows (the pipe is the waiting reader); the piped source and the
transformation's writable are locked; a second pipe from the same source
fails with `Locked`. (A pipe releases its locks when it finishes, so the
lock checks use a source that stays open.)
-}

-- CHECK: chain: A,B,C,D,E closed
-- CHECK: rendezvous chain: 1,2,3,4 closed
-- CHECK: read piped source: err Locked
-- CHECK: write piped writable: err Locked
-- CHECK: close piped writable: err Locked
-- CHECK: second pipe: err Locked
-- EXIT: 0

import Stream
import Stream.Transformation
import StreamCodecHelp exposing (readAll)
import StreamTestHelp exposing (describe)
import System
import Task exposing (Task)


upper : () -> String -> Stream.Transformation.CustomAction () String
upper state value =
    Stream.Transformation.Send { state = state, send = [ String.toUpper value ] }


chain : Task Stream.Error String
chain =
    Stream.fromList [ "a", "b", "c", "d", "e" ]
        |> Task.andThen (Stream.awaitAndPipeThrough Stream.Transformation.identity)
        |> Task.andThen (Stream.awaitAndPipeThrough (Stream.Transformation.custom upper ()))
        |> Task.andThen (Stream.awaitAndPipeThrough (Stream.Transformation.identityWith { readCapacity = 2, writeCapacity = 3 }))
        |> Task.andThen readAll
        |> Task.map (\values -> String.join "," values ++ " closed")


inc : () -> Int -> Stream.Transformation.CustomAction () Int
inc state value =
    Stream.Transformation.Send { state = state, send = [ value + 1 ] }


rendezvousChain : Task Stream.Error String
rendezvousChain =
    Stream.fromList [ 0, 1, 2, 3 ]
        |> Task.andThen (Stream.awaitAndPipeThrough (Stream.Transformation.customWith inc { initialState = (), readCapacity = 0, writeCapacity = 1 }))
        |> Task.andThen (Stream.awaitAndPipeThrough Stream.Transformation.identity)
        |> Task.andThen readAll
        |> Task.map (\values -> String.join "," (List.map String.fromInt values) ++ " closed")


locks : Task Stream.Error (List String)
locks =
    Task.map2 Tuple.pair Stream.Transformation.identity Stream.Transformation.identity
        |> Task.andThen
            (\( sourceT, t ) ->
                let
                    source =
                        Stream.Transformation.readable sourceT
                in
                Stream.pipeThrough t source
                    |> Task.andThen
                        (\_ ->
                            Task.map4 (\a b c d -> [ a, b, c, d ])
                                (describe (Stream.read source))
                                (describe (Stream.write "y" (Stream.Transformation.writable t)))
                                (describe (Stream.closeWritable (Stream.Transformation.writable t)))
                                (Stream.Transformation.identity |> Task.andThen (\t2 -> describe (Stream.pipeThrough t2 source)))
                        )
            )


main : Platform.Program System.Environment () ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.map3
                (\c r l ->
                    case l of
                        [ readResult, writeResult, closeResult, secondResult ] ->
                            [ "chain: " ++ c
                            , "rendezvous chain: " ++ r
                            , "read piped source: " ++ readResult
                            , "write piped writable: " ++ writeResult
                            , "close piped writable: " ++ closeResult
                            , "second pipe: " ++ secondResult
                            ]

                        _ ->
                            [ "unexpected" ]
                )
                chain
                rendezvousChain
                locks
        )
