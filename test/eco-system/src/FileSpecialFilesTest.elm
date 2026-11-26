module FileSpecialFilesTest exposing (main)

{-| Reads and writes the eco compiler relies on, which eco/kernel's `Eco.File` tests pinned
before the compiler's IO moved to eco/system (plans/compiler-io-on-eco-system.md §7.4):

  - a procfs file, which reports size 0, is read to its end (FILE-08, D22);
  - reading a directory fails with `DirectoryFound` (FILE-NEW-1);
  - writing to /dev/full fails with `NoSpace` (FILE-07);
  - a sparse 1 TiB + 1 byte file, larger than the heap, fails to read with an error instead of
    aborting the program (FILE-03);
  - the compiler's atomic write, a new temporary file written with `createNew` and `sync` and
    then moved over the target, replaces the target and leaves no temporary file behind.

-}

-- LINUX-ONLY: procfs, /dev/full
-- CHECK: proc: ok True
-- CHECK: directory: err DirectoryFound @
-- CHECK: dev-full: err NoSpace @full
-- CHECK: huge: err
-- CHECK: atomic: ok new
-- CHECK: atomic-left: ok [target]
-- CHECK: atomic-again: err FileExists @target.tmp-1
-- EXIT: 0

import FileSystem
import FileTestHelp exposing (attempt, bytes, child, file, fromBytes, withTempDir)
import Path
import System
import Task exposing (Task)


main : Platform.Program System.Environment () ()
main =
    FileTestHelp.program
        (\_ ->
            withTempDir
                (\dir ->
                    let
                        target =
                            child dir "target"

                        tmp =
                            child dir "target.tmp-1"

                        huge =
                            child dir "huge"
                    in
                    Task.sequence
                        [ attempt (\s -> if String.startsWith "Name:" s then "True" else "False")
                            (file (FileSystem.readFile (Path.fromPosixString "/proc/self/status")) |> Task.map fromBytes)
                            |> Task.map ((++) "proc: ")
                        , attempt (\_ -> "read")
                            (file (FileSystem.readFile dir))
                            |> Task.map (\s -> "directory: " ++ String.replace (" @" ++ Path.filenameWithExtension dir) " @" s)
                        , attempt (\_ -> "written")
                            (file (FileSystem.writeFile (bytes "x") (Path.fromPosixString "/dev/full")))
                            |> Task.map ((++) "dev-full: ")
                        , file (FileSystem.writeFile (bytes "") huge)
                            |> Task.andThen (\_ -> file (FileSystem.truncateFile 1099511627777 huge))
                            |> Task.andThen (\_ -> attempt (\_ -> "read") (file (FileSystem.readFile huge)))
                            |> Task.map ((++) "huge: ")
                        , file (FileSystem.writeFile (bytes "old") target)
                            |> Task.andThen (\_ -> file (FileSystem.writeFileWith { createNew = True, sync = True } (bytes "new") tmp))
                            |> Task.andThen (\_ -> file (FileSystem.move target tmp))
                            |> Task.andThen (\_ -> attempt fromBytes (file (FileSystem.readFile target)))
                            |> Task.map ((++) "atomic: ")
                        , attempt (\entries -> "[" ++ String.join "," (List.map (.path >> Path.toPosixString) entries) ++ "]")
                            (file (FileSystem.listDirectory dir |> Task.map (List.filter (\e -> Path.toPosixString e.path /= "huge"))))
                            |> Task.map ((++) "atomic-left: ")
                        , file (FileSystem.writeFile (bytes "x") tmp)
                            |> Task.andThen (\_ -> attempt (\_ -> "written") (file (FileSystem.writeFileWith { createNew = True, sync = True } (bytes "y") tmp)))
                            |> Task.map ((++) "atomic-again: ")
                        ]
                        |> Task.onError (\e -> Task.succeed [ "error: " ++ e ])
                )
        )
