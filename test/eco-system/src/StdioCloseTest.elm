module StdioCloseTest exposing (main)

{-| Closing an FdSink (plans/eco-system-library.md §3.4, §3.5): `enqueue`d and
written bytes all reach fd 1 before `closeWritable env.stdout` succeeds; later
writes fail with `Cancelled`. fd 1 itself is never closed, so stderr (and the
process) keep working.
-}

-- CHECK: enqueued line
-- CHECK: written line
-- CHECK: close: ok
-- CHECK: write after close: err Cancelled: WritableStream is closed
-- CHECK: close again: err Cancelled: WritableStream is closed
-- EXIT: 0

import Bytes
import Bytes.Encode
import Stream
import Stream.Log
import StreamTestHelp exposing (describe)
import System
import Task


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Stream.enqueue (toBytes "enqueued line\n") env.stdout
                    |> Task.andThen (Stream.writeLineAsBytes "written line")
                    |> describe
                    |> Task.andThen (\_ -> describe (Stream.closeWritable env.stdout))
                    |> Task.andThen
                        (\closeResult ->
                            Task.map2
                                (\w c ->
                                    String.join "\n"
                                        [ "close: " ++ closeResult
                                        , "write after close: " ++ w
                                        , "close again: " ++ c
                                        ]
                                )
                                (describe (Stream.writeLineAsBytes "too late" env.stdout))
                                (describe (Stream.closeWritable env.stdout))
                        )
                    |> Task.andThen (Stream.Log.line env.stderr)
                )
        )


toBytes : String -> Bytes.Bytes
toBytes s =
    Bytes.Encode.encode (Bytes.Encode.string s)
