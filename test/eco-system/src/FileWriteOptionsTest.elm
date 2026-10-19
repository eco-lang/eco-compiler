module FileWriteOptionsTest exposing (main)

{-| `FileSystem.writeFileWith` and `writeFileStreamWith`
(plans/eco-system-api-refactor.md D12): `createNew` creates a new file and
fails with `errorIsFileExists` when something is already there, without
touching it; `sync` writes like `writeFile`; the stream variant honours both,
with `sync` applied when the stream is closed.
-}

-- CHECK: create-new: ok new
-- CHECK: create-new-again: err EEXIST @a.txt True
-- CHECK: untouched: ok new
-- CHECK: sync: ok synced
-- CHECK: both: ok both
-- CHECK: stream-create-new: ok streamed
-- CHECK: stream-create-new-again: err EEXIST @s.txt True
-- CHECK: stream-sync-append: ok streamed+more
-- EXIT: 0

import FileSystem
import FileTestHelp exposing (attempt, bytes, child, file, fromBytes, rawError, stream)
import Path
import Stream
import System
import Task exposing (Task)


createNew : FileSystem.WriteOptions
createNew =
    { createNew = True, sync = False }


streamWrite : FileSystem.WriteOptions -> FileSystem.WriteFileStreamMode -> String -> Path.Path -> Task String Path.Path
streamWrite options mode text path =
    file (FileSystem.writeFileStreamWith options mode path)
        |> Task.andThen
            (\out ->
                stream (Stream.writeString text out)
                    |> Task.andThen (\_ -> stream (Stream.closeWritable out))
            )
        |> Task.map (\_ -> path)


exists : FileSystem.Error -> String
exists err =
    FileSystem.errorCode err
        ++ " @"
        ++ Path.filenameWithExtension (FileSystem.errorPath err)
        ++ " "
        ++ (if FileSystem.errorIsFileExists err then
                "True"

            else
                "False"
           )


main : Platform.Program System.Environment () ()
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

                        c =
                            child dir "c.txt"

                        s =
                            child dir "s.txt"
                    in
                    Task.sequence
                        [ attempt fromBytes (file (FileSystem.writeFileWith createNew (bytes "new") a |> Task.andThen FileSystem.readFile))
                            |> Task.map ((++) "create-new: ")
                        , rawError exists (FileSystem.writeFileWith createNew (bytes "other") a)
                            |> Task.map ((++) "create-new-again: err ")
                        , attempt fromBytes (file (FileSystem.readFile a))
                            |> Task.map ((++) "untouched: ")
                        , attempt fromBytes (file (FileSystem.writeFileWith { createNew = False, sync = True } (bytes "synced") b |> Task.andThen FileSystem.readFile))
                            |> Task.map ((++) "sync: ")
                        , attempt fromBytes (file (FileSystem.writeFileWith { createNew = True, sync = True } (bytes "both") c |> Task.andThen FileSystem.readFile))
                            |> Task.map ((++) "both: ")
                        , attempt fromBytes (streamWrite createNew FileSystem.Replace "streamed" s |> Task.andThen (\p -> file (FileSystem.readFile p)))
                            |> Task.map ((++) "stream-create-new: ")
                        , rawError exists (FileSystem.writeFileStreamWith createNew FileSystem.Replace s)
                            |> Task.map ((++) "stream-create-new-again: err ")
                        , attempt fromBytes (streamWrite { createNew = False, sync = True } FileSystem.Append "+more" s |> Task.andThen (\p -> file (FileSystem.readFile p)))
                            |> Task.map ((++) "stream-sync-append: ")
                        ]
                )
        )
