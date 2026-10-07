module EcoSystemFileStreams exposing (main)

{-| Stress variant of eco-system/FileStreamTest and FileHandleTest
(plans/eco-system-library.md Phase 4 step 4.6, §3.3.3 gate 3). Each cycle
streams `20 * maxSize` chunks of varying size into a file (FdSink), reads it
back through a file stream (FdSource, 64 KiB reads) and through `Between`
ranges, and rewrites it in place through a FileHandle with
`writeFromOffset` / `readFromOffset`.
-}

-- CHECK: EcoSystemFileStreams: True

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Stream
import StressHarness exposing (StressFlags)
import System.File as File
import System.File.FileHandle as FileHandle
import System.File.Path as Path exposing (Path)
import Task exposing (Task)


chunk : Int -> Int -> String
chunk cycleIx i =
    String.fromInt (i + cycleIx) ++ String.repeat (modBy 97 i) "x" ++ ";"


toBytes : String -> Bytes
toBytes s =
    Bytes.Encode.encode (Bytes.Encode.string s)


fromBytes : Bytes -> String
fromBytes b =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width b)) b |> Maybe.withDefault "<invalid>"


writeChunks : List String -> Stream.Writable Bytes -> Task Stream.Error ()
writeChunks chunks w =
    case chunks of
        [] ->
            Stream.closeWritable w

        c :: rest ->
            Stream.writeStringAsBytes c w |> Task.andThen (writeChunks rest)


readAll : Stream.Readable Bytes -> Task Stream.Error String
readAll r =
    Stream.readUntilClosed (\b acc -> Ok (b :: acc)) [] r
        |> Task.map (\parts -> fromBytes (Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.bytes (List.reverse parts)))))


type Failure
    = FileFailure
    | StreamFailure


fileTask : Task File.Error a -> Task Failure a
fileTask =
    Task.mapError (\_ -> FileFailure)


streamTask : Task Stream.Error a -> Task Failure a
streamTask =
    Task.mapError (\_ -> StreamFailure)


rangeChecks : Path -> String -> List ( Int, Int ) -> Task Failure Bool
rangeChecks path expected ranges =
    case ranges of
        [] ->
            Task.succeed True

        ( start, end ) :: rest ->
            fileTask (File.readFileStream (File.Between { start = start, end = end }) path)
                |> Task.andThen (\r -> streamTask (readAll r))
                |> Task.andThen
                    (\got ->
                        if got == String.slice start (end + 1) expected then
                            rangeChecks path expected rest

                        else
                            Task.succeed False
                    )


handleRewrite : Path -> String -> Task Failure Bool
handleRewrite path expected =
    fileTask (FileHandle.openForReadAndWrite FileHandle.ExpectExisting path)
        |> Task.andThen
            (\fh ->
                fileTask
                    (FileHandle.writeFromOffset fh 3 (toBytes "ABCDEFGH")
                        |> Task.andThen (\_ -> FileHandle.readFromOffset fh { offset = 0, length = 20 })
                        |> Task.andThen (\head -> FileHandle.close fh |> Task.map (\_ -> fromBytes head))
                    )
            )
        |> Task.map (\head -> head == String.left 20 (String.left 3 expected ++ "ABCDEFGH" ++ String.dropLeft 11 expected))


cycle : Int -> Int -> Task Never Bool
cycle n cycleIx =
    let
        chunks =
            List.map (chunk cycleIx) (List.range 0 (n - 1))

        expected =
            String.concat chunks

        len =
            String.length expected
    in
    fileTask (File.makeTempDirectory "eco-stress-streams-")
        |> Task.andThen
            (\dir ->
                let
                    path =
                        Path.appendPosixString "data.txt" dir
                in
                fileTask (File.writeFileStream File.Replace path)
                    |> Task.andThen (\w -> streamTask (writeChunks chunks w))
                    |> Task.andThen (\_ -> fileTask (File.readFileStream File.Beginning path))
                    |> Task.andThen (\r -> streamTask (readAll r))
                    |> Task.andThen
                        (\got ->
                            Task.map2 (&&)
                                (rangeChecks path expected [ ( 0, 0 ), ( 1, len // 2 ), ( len // 3, len - 1 ), ( len - 5, len + 100 ) ])
                                (handleRewrite path expected)
                                |> Task.map ((&&) (got == expected))
                        )
                    |> Task.andThen (\ok -> fileTask (File.remove { recursive = True } dir) |> Task.map (\_ -> ok))
            )
        |> Task.onError (\_ -> Task.succeed False)


run : StressFlags -> Task Never Bool
run flags =
    StressHarness.loopWhile flags (max 1 flags.numLoops) (cycle (20 * max 1 flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "EcoSystemFileStreams"
        , run = run
        }
