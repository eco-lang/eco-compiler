module FileHandleStaleTest exposing (main)

{-| FS-01 (plans/kernel-lib-bug-fixes.md): a `FileSystem.Handle` that was
closed must stay closed, even after the kernel hands its file descriptor
number to a newly opened file.

The test opens and closes `a.txt` (handle h1), then opens `b.txt` (handle
h2). POSIX and libuv both give out the lowest free descriptor, so h2 gets
h1's number. A `write`, `readFromOffset` or `truncate` on the stale h1 must
fail with `HandleClosed` and leave `b.txt` alone.

It failed on both backends while a handle was its raw fd and the kernels only
kept a set of open fds (S/FileSystem/FileSystem.cpp `openHandles()`,
FileSystem.js `_FileSystem_openHandles`): the reused number was accepted and
the stale operations acted on `b.txt`. Fixed on both backends (decision D5): a
handle is an opaque id that is never reused, mapped to its fd.

-}

-- CHECK: close h1: ok
-- CHECK: stale write: err HandleClosed @
-- CHECK: b after stale write: ok []
-- CHECK: h2 write: ok
-- CHECK: stale read: err HandleClosed @
-- CHECK: stale truncate: err HandleClosed @
-- CHECK: b after stale truncate: ok [data]
-- EXIT: 0

import Bytes
import FileSystem as File
import FileSystem.Handle as FileHandle
import FileTestHelp exposing (attempt, bytes, child, file, fromBytes)
import Path exposing (Path)
import Task exposing (Task)


label : String -> Task x String -> Task x String
label name =
    Task.map (\s -> name ++ ": " ++ s)


shown : Bytes.Bytes -> String
shown b =
    "[" ++ fromBytes b ++ "]"


unit : a -> String
unit _ =
    ""


run : Path -> Task String (List String)
run dir =
    let
        a =
            child dir "a.txt"

        b =
            child dir "b.txt"
    in
    file (FileHandle.openForReadAndWrite FileHandle.EnsureEmpty a)
        |> Task.andThen
            (\h1 ->
                attempt unit (file (FileHandle.close h1))
                    |> label "close h1"
                    |> Task.andThen
                        (\closed ->
                            file (FileHandle.openForReadAndWrite FileHandle.EnsureEmpty b)
                                |> Task.andThen
                                    (\h2 ->
                                        Task.sequence
                                            [ Task.succeed closed
                                            , attempt unit (file (FileHandle.write h1 (bytes "STALE"))) |> label "stale write"
                                            , attempt shown (file (File.readFile b)) |> label "b after stale write"
                                            , attempt unit
                                                (file (FileHandle.truncate 0 h2 |> Task.andThen (\h -> FileHandle.write h (bytes "data"))))
                                                |> label "h2 write"
                                            , attempt fromBytes (file (FileHandle.readFromOffset h1 { offset = 0, length = -1 }))
                                                |> label "stale read"
                                            , attempt unit (file (FileHandle.truncate 0 h1)) |> label "stale truncate"
                                            , attempt shown (file (File.readFile b)) |> label "b after stale truncate"
                                            ]
                                            |> Task.andThen
                                                (\lines ->
                                                    file (FileHandle.close h2) |> Task.map (\_ -> lines)
                                                )
                                    )
                        )
            )


main =
    FileTestHelp.program (\_ -> FileTestHelp.withTempDir run)
