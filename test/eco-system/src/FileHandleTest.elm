module FileHandleTest exposing (main)

{-| `System.File.FileHandle` (plans/eco-system-library.md Phase 4 step 4.6,
Appendix E.3): the open modes (`wx` on an existing file is EEXIST, `r+` keeps
the contents, `w+` empties the file), `write` at offset 0, `writeFromOffset`,
`readFromOffset` with offsets and negative lengths, `truncate`, `sync`,
`syncData`, `metadata` and the change functions on handles, and EBADF with
the empty error path after `close`.
-}

-- CHECK: open-new: ok
-- CHECK: write: ok
-- CHECK: write-offset: ok
-- CHECK: close-writer: ok
-- CHECK: open-wx-existing: err EEXIST @h.txt
-- CHECK: open-wx-existing-flag: True
-- CHECK: open-read-missing: err ENOENT @missing.txt
-- CHECK: read-all: ok hello world!
-- CHECK: read-offset: ok world
-- CHECK: read-negative-length: ok world!
-- CHECK: read-negative-offset: ok hel
-- CHECK: read-past-end: ok 0
-- CHECK: truncate: ok hello
-- CHECK: sync: ok
-- CHECK: syncdata: ok
-- CHECK: fstat: ok File 5
-- CHECK: fchmod: ok
-- CHECK: futimes: ok 1600000000000
-- CHECK: fchown: ok
-- CHECK: write-only-reopen: ok Xbc
-- CHECK: close-rw: ok
-- CHECK: after-close: err EBADF @
-- CHECK: after-close-path-empty: True
-- CHECK: close-twice: err EBADF @
-- CHECK: rw-ensure-empty: ok 0
-- CHECK: rw-expect-existing-missing: err ENOENT @nope.txt
-- CHECK: read-only-handle: ok hello
-- EXIT: 0

import Bytes
import FileTestHelp exposing (attempt, bytes, child, file, fromBytes)
import System
import System.File as File
import System.File.FileHandle as FileHandle
import System.File.Path as Path exposing (Path)
import Task exposing (Task)
import Time


label : String -> Task x String -> Task x String
label name =
    Task.map (\s -> name ++ ": " ++ s)


unit : a -> String
unit _ =
    ""


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


writePhase : Path -> Task String (List String)
writePhase h =
    file (FileHandle.openForWrite FileHandle.ExpectNotExisting h)
        |> Task.andThen
            (\w ->
                Task.sequence
                    [ Task.succeed "open-new: ok"
                    , attempt unit (file (FileHandle.write w (bytes "hello"))) |> label "write"
                    , attempt unit (file (FileHandle.writeFromOffset w 5 (bytes " world!"))) |> label "write-offset"
                    , attempt unit (file (FileHandle.close w)) |> label "close-writer"
                    ]
            )


openErrors : Path -> Path -> Task x (List String)
openErrors h dir =
    Task.sequence
        [ attempt unit (file (FileHandle.openForWrite FileHandle.ExpectNotExisting h)) |> label "open-wx-existing"
        , FileTestHelp.rawError (File.errorIsFileExists >> boolString) (FileHandle.openForReadAndWrite FileHandle.ExpectNotExisting h)
            |> label "open-wx-existing-flag"
        , attempt unit (file (FileHandle.openForRead (child dir "missing.txt"))) |> label "open-read-missing"
        ]


readWritePhase : Path -> Path -> Task String (List String)
readWritePhase h dir =
    file (FileHandle.openForReadAndWrite FileHandle.ExpectExisting h)
        |> Task.andThen
            (\rw ->
                Task.sequence
                    [ attempt fromBytes (file (FileHandle.read rw)) |> label "read-all"
                    , attempt fromBytes (file (FileHandle.readFromOffset rw { offset = 6, length = 5 })) |> label "read-offset"
                    , attempt fromBytes (file (FileHandle.readFromOffset rw { offset = 6, length = -1 }))
                        |> label "read-negative-length"
                    , attempt fromBytes (file (FileHandle.readFromOffset rw { offset = -4, length = 3 }))
                        |> label "read-negative-offset"
                    , attempt (Bytes.width >> String.fromInt) (file (FileHandle.readFromOffset rw { offset = 100, length = 10 }))
                        |> label "read-past-end"
                    , attempt fromBytes (file (FileHandle.truncate 5 rw |> Task.andThen FileHandle.read)) |> label "truncate"
                    , attempt unit (file (FileHandle.sync rw)) |> label "sync"
                    , attempt unit (file (FileHandle.syncData rw)) |> label "syncdata"
                    , attempt
                        (\m ->
                            (if m.entityType == File.File then
                                "File "

                             else
                                "Other "
                            )
                                ++ String.fromInt m.byteSize
                        )
                        (file (FileHandle.metadata (FileHandle.makeReadOnly rw)))
                        |> label "fstat"
                    , attempt unit
                        (file (FileHandle.changeAccess { owner = [ File.Read, File.Write ], group = [ File.Read ], others = [] } rw))
                        |> label "fchmod"
                    , attempt (\m -> String.fromInt (Time.posixToMillis m.lastModified))
                        (file
                            (FileHandle.changeTimes
                                { lastAccessed = Time.millisToPosix 1600000000500, lastModified = Time.millisToPosix 1600000000999 }
                                rw
                                |> Task.andThen FileHandle.metadata
                            )
                        )
                        |> label "futimes"
                    , attempt unit
                        (file
                            (FileHandle.metadata rw
                                |> Task.andThen (\m -> FileHandle.changeOwner { userID = m.userID, groupID = m.groupID } rw)
                            )
                        )
                        |> label "fchown"
                    , attempt fromBytes
                        (file
                            (FileHandle.openForWrite FileHandle.EnsureEmpty (child dir "w.txt")
                                |> Task.andThen (\w -> FileHandle.write w (bytes "abc"))
                                |> Task.andThen FileHandle.close
                                |> Task.andThen (\_ -> FileHandle.openForWrite FileHandle.ExpectExisting (child dir "w.txt"))
                                |> Task.andThen (\w -> FileHandle.write w (bytes "X"))
                                |> Task.andThen FileHandle.close
                                |> Task.andThen (\_ -> File.readFile (child dir "w.txt"))
                            )
                        )
                        |> label "write-only-reopen"
                    , attempt unit (file (FileHandle.close rw)) |> label "close-rw"
                    , attempt fromBytes (file (FileHandle.read rw)) |> label "after-close"
                    , FileTestHelp.rawError (\e -> boolString (File.errorPath e == Path.empty)) (FileHandle.sync rw)
                        |> label "after-close-path-empty"
                    , attempt unit (file (FileHandle.close rw)) |> label "close-twice"
                    ]
            )


reopenPhase : Path -> Path -> Task x (List String)
reopenPhase h dir =
    Task.sequence
        [ attempt (Bytes.width >> String.fromInt)
            (file
                (FileHandle.openForReadAndWrite FileHandle.EnsureEmpty (child dir "e.txt")
                    |> Task.andThen
                        (\e ->
                            FileHandle.write e (bytes "some")
                                |> Task.andThen FileHandle.close
                                |> Task.andThen (\_ -> FileHandle.openForReadAndWrite FileHandle.EnsureEmpty (child dir "e.txt"))
                                |> Task.andThen (\e2 -> FileHandle.read e2 |> Task.andThen (\b -> FileHandle.close e2 |> Task.map (\_ -> b)))
                        )
                )
            )
            |> label "rw-ensure-empty"
        , attempt unit (file (FileHandle.openForReadAndWrite FileHandle.ExpectExisting (child dir "nope.txt")))
            |> label "rw-expect-existing-missing"
        , attempt fromBytes
            (file
                (FileHandle.openForRead h
                    |> Task.andThen (\r -> FileHandle.read r |> Task.andThen (\b -> FileHandle.close r |> Task.map (\_ -> b)))
                )
            )
            |> label "read-only-handle"
        ]


main : System.SimpleProgram ()
main =
    FileTestHelp.program
        (\_ ->
            FileTestHelp.withTempDir
                (\dir ->
                    let
                        h =
                            child dir "h.txt"
                    in
                    Task.map4 (\a b c d -> a ++ b ++ c ++ d)
                        (writePhase h)
                        (openErrors h dir)
                        (readWritePhase h dir)
                        (reopenPhase h dir)
                )
        )
