module FileDirectoryTest exposing (main)

{-| `System.File.makeDirectory`, `listDirectory` and `makeTempDirectory`
(plans/eco-system-library.md Phase 4 step 4.6, Appendix E.3): recursive
mkdir, listings sorted by `strcmp` with entity types, and temp directories
named `<tmpDirectory>/<prefix>XXXXXX`.
-}

-- CHECK: mkdir: ok one
-- CHECK: mkdir-exists: err EEXIST @one
-- CHECK: mkdir-exists-flag: True
-- CHECK: mkdir-nested-nonrecursive: err ENOENT @c
-- CHECK: mkdir-recursive: ok c
-- CHECK: mkdir-recursive-exists: ok c
-- CHECK: mkdir-recursive-over-file: err EEXIST @f.txt
-- CHECK: mkdir-recursive-through-file: err ENOTDIR @sub
-- CHECK: mkdir-through-file-flag: True
-- CHECK: list: ok [B.txt:File,a:Directory,f.txt:File,l:Symlink,one:Directory,z.txt:File]
-- CHECK: list-nested: ok [b:Directory]
-- CHECK: list-empty: ok []
-- CHECK: list-missing: err ENOENT @nope
-- CHECK: list-file: err ENOTDIR @f.txt
-- CHECK: tempdir: True True True
-- CHECK: tempdir-missing-parent: err ENOENT @x-
-- EXIT: 0

import FileTestHelp exposing (attempt, bytes, child, file)
import System
import System.File as File
import System.File.Path as Path
import Task exposing (Task)


label : String -> Task x String -> Task x String
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


showListing : List { path : Path.Path, entityType : File.EntityType } -> String
showListing entries =
    "["
        ++ String.join "," (List.map (\e -> Path.toPosixString e.path ++ ":" ++ entityName e.entityType) entries)
        ++ "]"


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


tempDirCheck : Task String String
tempDirCheck =
    file
        (Task.map3
            (\tmp t1 t2 ->
                [ boolString (String.startsWith "eco-p4-check-" (Path.filenameWithExtension t1))
                , boolString (Maybe.map Path.toPosixString (Path.parentPath t1) == Just (Path.toPosixString tmp))
                , boolString (t1 /= t2)
                ]
                    |> (\flags -> ( flags, t1, t2 ))
            )
            File.tmpDirectory
            (File.makeTempDirectory "eco-p4-check-")
            (File.makeTempDirectory "eco-p4-check-")
            |> Task.andThen
                (\( flags, t1, t2 ) ->
                    File.remove { recursive = True } t1
                        |> Task.andThen (\_ -> File.remove { recursive = True } t2)
                        |> Task.map (\_ -> String.join " " flags)
                )
        )


main : System.SimpleProgram ()
main =
    FileTestHelp.program
        (\_ ->
            FileTestHelp.withTempDir
                (\dir ->
                    let
                        one =
                            child dir "one"

                        f =
                            child dir "f.txt"
                    in
                    Task.sequence
                        [ attempt Path.filenameWithExtension (file (File.makeDirectory { recursive = False } one))
                            |> label "mkdir"
                        , attempt Path.filenameWithExtension (file (File.makeDirectory { recursive = False } one))
                            |> label "mkdir-exists"
                        , FileTestHelp.rawError (File.errorIsFileExists >> boolString) (File.makeDirectory { recursive = False } one)
                            |> label "mkdir-exists-flag"
                        , attempt Path.filenameWithExtension (file (File.makeDirectory { recursive = False } (child dir "a/b/c")))
                            |> label "mkdir-nested-nonrecursive"
                        , attempt Path.filenameWithExtension (file (File.makeDirectory { recursive = True } (child dir "a/b/c")))
                            |> label "mkdir-recursive"
                        , attempt Path.filenameWithExtension (file (File.makeDirectory { recursive = True } (child dir "a/b/c")))
                            |> label "mkdir-recursive-exists"
                        , attempt Path.filenameWithExtension
                            (file (File.writeFile (bytes "f") f |> Task.andThen (File.makeDirectory { recursive = True })))
                            |> label "mkdir-recursive-over-file"
                        , attempt Path.filenameWithExtension (file (File.makeDirectory { recursive = True } (child dir "f.txt/sub")))
                            |> label "mkdir-recursive-through-file"
                        , FileTestHelp.rawError (File.errorIsNotADirectory >> boolString)
                            (File.makeDirectory { recursive = True } (child dir "f.txt/sub"))
                            |> label "mkdir-through-file-flag"
                        , attempt showListing
                            (file
                                (File.writeFile (bytes "z") (child dir "z.txt")
                                    |> Task.andThen (\_ -> File.writeFile (bytes "B") (child dir "B.txt"))
                                    |> Task.andThen (\_ -> File.softLink (child dir "l") f)
                                    |> Task.andThen (\_ -> File.listDirectory dir)
                                )
                            )
                            |> label "list"
                        , attempt showListing (file (File.listDirectory (child dir "a"))) |> label "list-nested"
                        , attempt showListing (file (File.listDirectory (child dir "a/b/c"))) |> label "list-empty"
                        , attempt showListing (file (File.listDirectory (child dir "nope"))) |> label "list-missing"
                        , attempt showListing (file (File.listDirectory f)) |> label "list-file"
                        , tempDirCheck
                            |> Task.onError (\e -> Task.succeed ("err " ++ e))
                            |> label "tempdir"
                        , attempt Path.filenameWithExtension (file (File.makeTempDirectory "no/such/dir/x-"))
                            |> label "tempdir-missing-parent"
                        ]
                )
        )
