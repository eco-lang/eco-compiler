module FileStreamTest exposing (main)

{-| File streams (plans/eco-system-library.md Phase 4 step 4.6, Appendix
E.3): `writeFileStream` in the three modes (`ReplaceFrom n` keeps the first
`n` bytes and cuts the file at the end of the streamed data on close),
`readFileStream` from the beginning, `From n` and `Between` (inclusive end),
open errors reported by the task itself, and a 300 000 byte file read in
several chunks.
-}

-- CHECK: wstream-replace: ok chunk1chunk2chunk3
-- CHECK: rstream-beginning: ok chunk1chunk2chunk3
-- CHECK: rstream-from: ok chunk2chunk3
-- CHECK: rstream-between: ok nk2c
-- CHECK: rstream-between-one: ok c
-- CHECK: rstream-between-empty: ok <>
-- CHECK: rstream-between-past-end: ok k3
-- CHECK: wstream-append: ok chunk1chunk2chunk3++
-- CHECK: wstream-append-creates: ok new
-- CHECK: wstream-replacefrom: ok chunk1XY
-- CHECK: wstream-replacefrom-zero: ok Z
-- CHECK: wstream-replacefrom-missing: err ENOENT @nofile.txt
-- CHECK: rstream-missing: err ENOENT @missing.txt
-- CHECK: rstream-dir: err EISDIR @sub
-- CHECK: big: ok 300000 True True
-- CHECK: read-after-eof: ok closed
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Encode
import FileTestHelp exposing (attempt, bytes, child, file, fromBytes, stream)
import Stream
import System
import System.File as File
import System.File.Path exposing (Path)
import Task exposing (Task)


label : String -> Task x String -> Task x String
label name =
    Task.map (\s -> name ++ ": " ++ s)


writeChunks : List String -> Stream.Writable Bytes -> Task String ()
writeChunks chunks w =
    case chunks of
        [] ->
            stream (Stream.closeWritable w)

        c :: rest ->
            stream (Stream.writeStringAsBytes c w) |> Task.andThen (writeChunks rest)


streamWrite : File.WriteFileStreamMode -> List String -> Path -> Task String ()
streamWrite mode chunks path =
    file (File.writeFileStream mode path) |> Task.andThen (writeChunks chunks)


streamRead : File.ReadFileStreamMode -> Path -> Task String String
streamRead mode path =
    file (File.readFileStream mode path)
        |> Task.andThen (\r -> stream (readAll r))
        |> Task.map
            (\s ->
                if s == "" then
                    "<>"

                else
                    s
            )


{-| Every chunk until the stream closes, as one UTF-8 string.
-}
readAll : Stream.Readable Bytes -> Task Stream.Error String
readAll r =
    Stream.readUntilClosed (\chunk acc -> Ok (chunk :: acc)) [] r
        |> Task.map (\chunks -> fromBytes (Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.bytes (List.reverse chunks)))))


bigCheck : Path -> Task String String
bigCheck dir =
    let
        big =
            child dir "big.bin"

        content =
            Bytes.Encode.encode (Bytes.Encode.sequence (List.repeat 300000 (Bytes.Encode.unsignedInt8 97)))
    in
    file (File.writeFile content big)
        |> Task.andThen (\_ -> file (File.readFileStream File.Beginning big))
        |> Task.andThen
            (\r ->
                stream (Stream.readUntilClosed (\chunk ( n, k, allA ) -> Ok ( n + Bytes.width chunk, k + 1, allA && Bytes.width chunk > 0 )) ( 0, 0, True ) r)
            )
        |> Task.map
            (\( n, k, nonEmpty ) ->
                String.fromInt n
                    ++ (if k > 1 then
                            " True"

                        else
                            " False"
                       )
                    ++ (if nonEmpty then
                            " True"

                        else
                            " False"
                       )
            )


readAfterEof : Path -> Task String String
readAfterEof path =
    file (File.readFileStream File.Beginning path)
        |> Task.andThen (\r -> stream (readAll r) |> Task.map (\_ -> r))
        |> Task.andThen
            (\r ->
                Stream.read r
                    |> Task.map (\_ -> "more data")
                    |> Task.onError
                        (\e ->
                            case e of
                                Stream.Closed ->
                                    Task.succeed "closed"

                                _ ->
                                    Task.succeed ("other " ++ Stream.errorToString e)
                        )
            )


main : System.SimpleProgram ()
main =
    FileTestHelp.program
        (\_ ->
            FileTestHelp.withTempDir
                (\dir ->
                    let
                        f =
                            child dir "s.txt"
                    in
                    Task.sequence
                        [ attempt fromBytes
                            (streamWrite File.Replace [ "chunk1", "chunk2", "chunk3" ] f
                                |> Task.andThen (\_ -> file (File.readFile f))
                            )
                            |> label "wstream-replace"
                        , attempt identity (streamRead File.Beginning f) |> label "rstream-beginning"
                        , attempt identity (streamRead (File.From 6) f) |> label "rstream-from"
                        , attempt identity (streamRead (File.Between { start = 9, end = 12 }) f) |> label "rstream-between"
                        , attempt identity (streamRead (File.Between { start = 12, end = 12 }) f) |> label "rstream-between-one"
                        , attempt identity (streamRead (File.Between { start = 5, end = 2 }) f) |> label "rstream-between-empty"
                        , attempt identity (streamRead (File.Between { start = 16, end = 100 }) f) |> label "rstream-between-past-end"
                        , attempt fromBytes
                            (streamWrite File.Append [ "+", "+" ] f |> Task.andThen (\_ -> file (File.readFile f)))
                            |> label "wstream-append"
                        , attempt fromBytes
                            (streamWrite File.Append [ "new" ] (child dir "created.txt")
                                |> Task.andThen (\_ -> file (File.readFile (child dir "created.txt")))
                            )
                            |> label "wstream-append-creates"
                        , attempt fromBytes
                            (streamWrite (File.ReplaceFrom 6) [ "X", "Y" ] f |> Task.andThen (\_ -> file (File.readFile f)))
                            |> label "wstream-replacefrom"
                        , attempt fromBytes
                            (streamWrite (File.ReplaceFrom 0) [ "Z" ] f |> Task.andThen (\_ -> file (File.readFile f)))
                            |> label "wstream-replacefrom-zero"
                        , attempt (\_ -> "") (streamWrite (File.ReplaceFrom 3) [ "Q" ] (child dir "nofile.txt"))
                            |> label "wstream-replacefrom-missing"
                        , attempt identity (streamRead File.Beginning (child dir "missing.txt")) |> label "rstream-missing"
                        , attempt identity
                            (file (File.makeDirectory { recursive = False } (child dir "sub"))
                                |> Task.andThen (streamRead File.Beginning)
                            )
                            |> label "rstream-dir"
                        , attempt identity (bigCheck dir) |> label "big"
                        , attempt identity (readAfterEof f) |> label "read-after-eof"
                        ]
                )
        )
