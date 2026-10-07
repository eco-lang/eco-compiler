module FileRemoveTest exposing (main)

{-| `System.File.remove` and `unlink` (plans/eco-system-library.md Phase 4
step 4.6, Appendix E.3): removing a directory without `recursive` fails with
node's code `ERR_FS_EISDIR` (so `errorIsDirectoryFound` is False), recursive
removal deletes a whole tree, a symlink to a directory is removed as a link.
-}

-- CHECK: remove-file: ok f.txt
-- CHECK: remove-file-gone: err ENOENT @f.txt
-- CHECK: remove-dir-nonrecursive: err ERR_FS_EISDIR @d
-- CHECK: remove-dir-flags: False Path is a directory
-- CHECK: remove-dir-still-there: ok Directory
-- CHECK: remove-dir-recursive: ok d
-- CHECK: remove-dir-gone: err ENOENT @d
-- CHECK: remove-missing: err ENOENT @missing
-- CHECK: remove-recursive-missing: err ENOENT @missing
-- CHECK: remove-symlink-to-dir: ok [keep]
-- CHECK: unlink: ok u.txt
-- CHECK: unlink-missing: err ENOENT @u.txt
-- CHECK: unlink-dir: err EISDIR @keep
-- EXIT: 0

import FileTestHelp exposing (attempt, bytes, child, file, rawError)
import System
import System.File as File
import System.File.Path as Path
import Task


label : String -> Task.Task x String -> Task.Task x String
label name =
    Task.map (\s -> name ++ ": " ++ s)


entityName : File.EntityType -> String
entityName e =
    case e of
        File.File ->
            "File"

        File.Directory ->
            "Directory"

        File.Socket ->
            "Socket"

        File.Symlink ->
            "Symlink"

        File.Device ->
            "Device"

        File.Pipe ->
            "Pipe"


main : System.SimpleProgram ()
main =
    FileTestHelp.program
        (\_ ->
            FileTestHelp.withTempDir
                (\dir ->
                    let
                        f =
                            child dir "f.txt"

                        d =
                            child dir "d"

                        missing =
                            child dir "missing"

                        keep =
                            child dir "keep"
                    in
                    Task.sequence
                        [ attempt Path.filenameWithExtension
                            (file (File.writeFile (bytes "x") f |> Task.andThen (File.remove { recursive = False })))
                            |> label "remove-file"
                        , attempt (\_ -> "") (file (File.readFile f)) |> label "remove-file-gone"
                        , attempt Path.filenameWithExtension
                            (file
                                (File.makeDirectory { recursive = True } (child d "a/b")
                                    |> Task.andThen (\_ -> File.writeFile (bytes "deep") (child d "a/b/c.txt"))
                                    |> Task.andThen (\_ -> File.writeFile (bytes "top") (child d "top.txt"))
                                    |> Task.andThen (\_ -> File.remove { recursive = False } d)
                                )
                            )
                            |> label "remove-dir-nonrecursive"
                        , rawError
                            (\e ->
                                (if File.errorIsDirectoryFound e then
                                    "True "

                                 else
                                    "False "
                                )
                                    ++ File.errorToString e
                            )
                            (File.remove { recursive = False } d)
                            |> label "remove-dir-flags"
                        , attempt (.entityType >> entityName) (file (File.metadata { resolveLink = True } d))
                            |> label "remove-dir-still-there"
                        , attempt Path.filenameWithExtension (file (File.remove { recursive = True } d))
                            |> label "remove-dir-recursive"
                        , attempt (\_ -> "") (file (File.metadata { resolveLink = False } d)) |> label "remove-dir-gone"
                        , attempt (\_ -> "") (file (File.remove { recursive = False } missing)) |> label "remove-missing"
                        , attempt (\_ -> "") (file (File.remove { recursive = True } missing)) |> label "remove-recursive-missing"
                        , attempt
                            (List.map (.path >> Path.filenameWithExtension) >> String.join "," >> (\s -> "[" ++ s ++ "]"))
                            (file
                                (File.makeDirectory { recursive = False } keep
                                    |> Task.andThen (\_ -> File.writeFile (bytes "k") (child keep "k.txt"))
                                    |> Task.andThen (\_ -> File.softLink (child dir "link") keep)
                                    |> Task.andThen (File.remove { recursive = False })
                                    |> Task.andThen (\_ -> File.listDirectory dir)
                                )
                            )
                            |> label "remove-symlink-to-dir"
                        , attempt Path.filenameWithExtension
                            (file (File.writeFile (bytes "u") (child dir "u.txt") |> Task.andThen File.unlink))
                            |> label "unlink"
                        , attempt (\_ -> "") (file (File.unlink (child dir "u.txt"))) |> label "unlink-missing"
                        , attempt (\_ -> "") (file (File.unlink keep)) |> label "unlink-dir"
                        ]
                )
        )
