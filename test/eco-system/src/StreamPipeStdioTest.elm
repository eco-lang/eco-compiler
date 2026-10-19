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
import Stream.Transformation
import StreamTestHelp exposing (describe)
import System
import Task


capitalL : () -> String -> Stream.Transformation.CustomAction () String
capitalL state value =
    Stream.Transformation.Send { state = state, send = [ String.replace "l" "L" value ] }


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            Stream.awaitAndPipeThrough Stream.Transformation.textDecoder env.stdin
                |> Task.andThen (Stream.awaitAndPipeThrough (Stream.Transformation.custom capitalL ()))
                |> Task.andThen (Stream.awaitAndPipeThrough Stream.Transformation.textEncoder)
                |> Task.andThen (Stream.pipeTo env.stdout)
                |> describe
                |> Task.andThen
                    (\piped ->
                        describe (Stream.writeLine "late" env.stdout)
                            |> Task.andThen
                                (\late ->
                                    Stream.logLine ("done: " ++ piped ++ ", then stdout write " ++ late) env.stderr
                                )
                    )
        )
