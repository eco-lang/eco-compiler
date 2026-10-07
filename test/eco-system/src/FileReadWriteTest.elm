module FileReadWriteTest exposing (main)

{-| `System.File` whole-file operations (plans/eco-system-library.md Phase 4
step 4.6, Appendix E.3): writeFile, readFile, appendToFile (creates the file),
truncateFile (shrinks and zero-extends), and their errors: a missing file is
ENOENT with the path, reading a directory is EISDIR, `errorToString` is node's
message.
-}

-- CHECK: write: ok a.txt
-- CHECK: read: ok hello
-- CHECK: overwrite: ok bye
-- CHECK: append-new: ok abc
-- CHECK: append-again: ok abcdef
-- CHECK: truncate-shrink: ok [98,121]
-- CHECK: truncate-grow: ok [98,121,0,0,0]
-- CHECK: empty-file: ok 0
-- CHECK: read-missing: err ENOENT @nope.txt
-- CHECK: read-missing-is-enoent: True True ENOENT: no such file or directory, open
-- CHECK: read-dir: err EISDIR @sub
-- CHECK: write-into-missing-dir: err ENOENT @x.txt
-- CHECK: truncate-missing: err ENOENT @nope.txt
-- CHECK: utf8: ok héllo wörld ✓
-- EXIT: 0

import Bytes
import FileTestHelp exposing (attempt, byteList, bytes, child, file, fromBytes, rawError)
import System
import System.File as File
import System.File.Path as Path
import Task


main : System.SimpleProgram ()
main =
    FileTestHelp.program
        (\_ ->
            FileTestHelp.withTempDir
                (\dir ->
                    let
                        a =
                            child dir "a.txt"

                        b =
                            child dir "b.txt"

                        missing =
                            child dir "nope.txt"
                    in
                    Task.sequence
                        [ attempt Path.filenameWithExtension (file (File.writeFile (bytes "hello") a))
                            |> Task.map ((++) "write: ")
                        , attempt fromBytes (file (File.readFile a))
                            |> Task.map ((++) "read: ")
                        , attempt fromBytes (file (File.writeFile (bytes "bye") a |> Task.andThen File.readFile))
                            |> Task.map ((++) "overwrite: ")
                        , attempt fromBytes (file (File.appendToFile (bytes "abc") b |> Task.andThen File.readFile))
                            |> Task.map ((++) "append-new: ")
                        , attempt fromBytes (file (File.appendToFile (bytes "def") b |> Task.andThen File.readFile))
                            |> Task.map ((++) "append-again: ")
                        , attempt (byteList >> FileTestHelp.showInts) (file (File.truncateFile 2 a |> Task.andThen File.readFile))
                            |> Task.map ((++) "truncate-shrink: ")
                        , attempt (byteList >> FileTestHelp.showInts) (file (File.truncateFile 5 a |> Task.andThen File.readFile))
                            |> Task.map ((++) "truncate-grow: ")
                        , attempt (Bytes.width >> String.fromInt)
                            (file (File.writeFile (bytes "") (child dir "empty") |> Task.andThen File.readFile))
                            |> Task.map ((++) "empty-file: ")
                        , attempt fromBytes (file (File.readFile missing))
                            |> Task.map ((++) "read-missing: ")
                        , rawError
                            (\e ->
                                (if File.errorIsNoSuchFileOrDirectory e then
                                    "True"

                                 else
                                    "False"
                                )
                                    ++ (if File.errorPath e == missing then
                                            " True "

                                        else
                                            " False "
                                       )
                                    ++ File.errorToString e
                            )
                            (File.readFile missing)
                            |> Task.map ((++) "read-missing-is-enoent: ")
                        , attempt fromBytes (file (File.makeDirectory { recursive = False } (child dir "sub") |> Task.andThen File.readFile))
                            |> Task.map ((++) "read-dir: ")
                        , attempt Path.filenameWithExtension (file (File.writeFile (bytes "x") (child dir "no/such/x.txt")))
                            |> Task.map ((++) "write-into-missing-dir: ")
                        , attempt Path.filenameWithExtension (file (File.truncateFile 1 missing))
                            |> Task.map ((++) "truncate-missing: ")
                        , attempt fromBytes (file (File.writeFile (bytes "héllo wörld ✓") a |> Task.andThen File.readFile))
                            |> Task.map ((++) "utf8: ")
                        ]
                )
        )
