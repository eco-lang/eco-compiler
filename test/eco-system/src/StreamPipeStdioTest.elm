module StreamPipeStdioTest exposing (main)

{-| Pipes over byte channels (plans/eco-system-library.md §3.5, Phase 6):
stdin (an FdSource, read by the pipe) → textDecoder → custom (l → L) →
textEncoder → stdout (an FdSink, written by the pipe). `pipeTo` completes
when stdin reaches end of file and stdout has been closed (fd 1 itself stays
open, §3.4), after which writing to stdout fails.
-}

-- STDIN: héllo\n
-- STDIN: wörld\n
-- CHECK: héLLo
-- CHECK: wörLd
-- CHECK: done: ok, then stdout write err Cancelled: WritableStream is closed
-- EXIT: 0

import Stream
import Stream.Log
import StreamTestHelp exposing (describe)
import System
import Task


capitalL : () -> String -> Stream.CustomTransformationAction () String
capitalL state value =
    Stream.Send { state = state, send = [ String.replace "l" "L" value ] }


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Stream.awaitAndPipeThrough Stream.textDecoder env.stdin
                    |> Task.andThen (Stream.awaitAndPipeThrough (Stream.customTransformation capitalL ()))
                    |> Task.andThen (Stream.awaitAndPipeThrough Stream.textEncoder)
                    |> Task.andThen (Stream.pipeTo env.stdout)
                    |> describe
                    |> Task.andThen
                        (\piped ->
                            describe (Stream.writeLineAsBytes "late" env.stdout)
                                |> Task.andThen
                                    (\late ->
                                        Stream.Log.line env.stderr ("done: " ++ piped ++ ", then stdout write " ++ late)
                                    )
                        )
                )
        )
