module EcoSystemFileManySmall exposing (main)

{-| Stress variant of the eco-system file tests (plans/eco-system-library.md
Phase 4 step 4.6, §3.3.3 gate 3): each cycle creates a temporary directory,
writes `10 * maxSize` small files (1 000 with the default size), lists the
directory (checking the strcmp order and entity types), reads every file back
and compares its contents, reads their metadata through a FileHandle, and
removes the tree. Every operation is one SysWorkPool job whose result is built
on the main thread (Bytes, String lists, metadata lists).
-}

-- CHECK: EcoSystemFileManySmall: True

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import StressHarness exposing (StressFlags)
import System.File as File
import System.File.FileHandle as FileHandle
import System.File.Path as Path exposing (Path)
import Task exposing (Task)


name : Int -> String
name i =
    "f" ++ String.padLeft 6 '0' (String.fromInt i)


content : Int -> Int -> String
content cycleIx i =
    "file " ++ String.fromInt i ++ " of cycle " ++ String.fromInt cycleIx ++ String.repeat (modBy 7 i) "."


toBytes : String -> Bytes
toBytes s =
    Bytes.Encode.encode (Bytes.Encode.string s)


fromBytes : Bytes -> String
fromBytes b =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width b)) b |> Maybe.withDefault "<invalid>"


writeAll : Path -> Int -> Int -> Int -> Task File.Error ()
writeAll dir cycleIx i n =
    if i >= n then
        Task.succeed ()

    else
        File.writeFile (toBytes (content cycleIx i)) (Path.appendPosixString (name i) dir)
            |> Task.andThen (\_ -> writeAll dir cycleIx (i + 1) n)


readAll : Path -> Int -> Int -> Int -> Task File.Error Bool
readAll dir cycleIx i n =
    if i >= n then
        Task.succeed True

    else
        File.readFile (Path.appendPosixString (name i) dir)
            |> Task.andThen
                (\b ->
                    if fromBytes b == content cycleIx i then
                        readAll dir cycleIx (i + 1) n

                    else
                        Task.succeed False
                )


{-| Every 50th file: open, fstat, read through the handle, close.
-}
handleCheck : Path -> Int -> Int -> Int -> Task File.Error Bool
handleCheck dir cycleIx i n =
    if i >= n then
        Task.succeed True

    else
        FileHandle.openForRead (Path.appendPosixString (name i) dir)
            |> Task.andThen
                (\fh ->
                    Task.map2 Tuple.pair (FileHandle.metadata fh) (FileHandle.read fh)
                        |> Task.andThen (\pair -> FileHandle.close fh |> Task.map (\_ -> pair))
                )
            |> Task.andThen
                (\( meta, b ) ->
                    let
                        expected =
                            content cycleIx i
                    in
                    if meta.byteSize == String.length expected && fromBytes b == expected then
                        handleCheck dir cycleIx (i + 50) n

                    else
                        Task.succeed False
                )


cycle : Int -> Int -> Task Never Bool
cycle n cycleIx =
    File.makeTempDirectory "eco-stress-files-"
        |> Task.andThen
            (\dir ->
                writeAll dir cycleIx 0 n
                    |> Task.andThen (\_ -> File.listDirectory dir)
                    |> Task.andThen
                        (\entries ->
                            let
                                listingOk =
                                    List.map (\e -> ( Path.toPosixString e.path, e.entityType )) entries
                                        == List.map (\i -> ( name i, File.File )) (List.range 0 (n - 1))
                            in
                            Task.map2 (&&) (readAll dir cycleIx 0 n) (handleCheck dir cycleIx 0 n)
                                |> Task.map ((&&) listingOk)
                        )
                    |> Task.andThen (\ok -> File.remove { recursive = True } dir |> Task.map (\_ -> ok))
            )
        |> Task.onError (\_ -> Task.succeed False)


run : StressFlags -> Task Never Bool
run flags =
    StressHarness.loopWhile flags (max 1 flags.numLoops) (cycle (10 * max 1 flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "EcoSystemFileManySmall"
        , run = run
        }
