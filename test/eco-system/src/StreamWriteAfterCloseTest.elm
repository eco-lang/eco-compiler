module StreamWriteAfterCloseTest exposing (main)

{-| Writing to a closed writable (plans/eco-system-library.md §3.5): `write`,
`enqueue` and a second `closeWritable` all fail with
`Cancelled "WritableStream is closed"` (for `enqueue` this deliberately differs
from gren, which produced an unhandled rejection).
-}

-- CHECK: write: err Cancelled: WritableStream is closed
-- CHECK: enqueue: err Cancelled: WritableStream is closed
-- CHECK: close again: err Cancelled: WritableStream is closed
-- CHECK: value before close: 5
-- EXIT: 0

import Stream
import StreamTestHelp
import System
import Task


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Stream.identityTransformation
                |> Task.andThen
                    (\t ->
                        Stream.write 5 (Stream.writable t)
                            |> Task.andThen Stream.closeWritable
                            |> Task.andThen
                                (\_ ->
                                    Task.map4
                                        (\w e c v ->
                                            [ "write: " ++ w
                                            , "enqueue: " ++ e
                                            , "close again: " ++ c
                                            , "value before close: " ++ String.fromInt v
                                            ]
                                        )
                                        (StreamTestHelp.describe (Stream.write 6 (Stream.writable t)))
                                        (StreamTestHelp.describe (Stream.enqueue 7 (Stream.writable t)))
                                        (StreamTestHelp.describe (Stream.closeWritable (Stream.writable t)))
                                        (Stream.read (Stream.readable t))
                                )
                    )
        )
