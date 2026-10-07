module StreamReadUntilClosedTest exposing (main)

{-| `readUntilClosed` over 10 000 chunks (plans/eco-system-library.md Phase 3
step 3.6): a spawned writer pushes 1..10000 through identity(1,1), then closes;
the reader folds them. Every chunk crosses a parked read or a parked write.
An `Err` from the step function cancels the stream with its reason.
-}

-- CHECK: count: 10000
-- CHECK: sum: 50005000
-- CHECK: stop early: err Cancelled: too big
-- EXIT: 0

import Process
import Stream
import StreamTestHelp
import System
import Task exposing (Task)


writeFrom : Int -> Int -> Stream.Writable Int -> Task Stream.Error ()
writeFrom i n w =
    if i > n then
        Stream.closeWritable w

    else
        Stream.write i w |> Task.andThen (writeFrom (i + 1) n)


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Stream.identityTransformation
                |> Task.andThen
                    (\t ->
                        Process.spawn (writeFrom 1 10000 (Stream.writable t) |> Task.onError (\_ -> Task.succeed ()))
                            |> Task.andThen
                                (\_ ->
                                    Stream.readUntilClosed
                                        (\v ( count, sum ) -> Ok ( count + 1, sum + v ))
                                        ( 0, 0 )
                                        (Stream.readable t)
                                )
                    )
                |> Task.andThen
                    (\( count, sum ) ->
                        Stream.fromList [ 1, 2, 300, 4 ]
                            |> Task.andThen
                                (\r ->
                                    StreamTestHelp.describe
                                        (Stream.readUntilClosed
                                            (\v acc ->
                                                if v > 100 then
                                                    Err "too big"

                                                else
                                                    Ok (acc + v)
                                            )
                                            0
                                            r
                                        )
                                )
                            |> Task.map
                                (\early ->
                                    [ "count: " ++ String.fromInt count
                                    , "sum: " ++ String.fromInt sum
                                    , "stop early: " ++ early
                                    ]
                                )
                    )
        )
