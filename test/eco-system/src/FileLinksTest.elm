module FileLinksTest exposing (main)

{-| Links (plans/eco-system-library.md Phase 4 step 4.6, Appendix E.3):
`hardLink link target` / `softLink link target` (gren's argument order),
`readLink`, `realPath` through a symlink, `metadata` with and without
`resolveLink`, dangling links and link loops (`errorIsLinkLoop`).
-}

-- CHECK: hardlink: ok hard.txt
-- CHECK: hardlink-content: ok data
-- CHECK: hardlink-exists: err EEXIST @hard.txt
-- CHECK: softlink: ok soft.txt
-- CHECK: readlink: ok target.txt
-- CHECK: readlink-not-link: err EINVAL @target.txt
-- CHECK: softlink-content: ok data
-- CHECK: lstat-softlink: ok Symlink
-- CHECK: stat-softlink: ok File
-- CHECK: realpath-softlink: ok True
-- CHECK: dangling-stat: err ENOENT @dangling
-- CHECK: dangling-lstat: ok Symlink
-- CHECK: loop: True
-- CHECK: unlink-links: ok [hard.txt,target.txt]
-- EXIT: 0

import FileTestHelp exposing (attempt, bytes, child, file, fromBytes)
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


main : System.SimpleProgram ()
main =
    FileTestHelp.program
        (\_ ->
            FileTestHelp.withTempDir
                (\dir ->
                    let
                        target =
                            child dir "target.txt"

                        hard =
                            child dir "hard.txt"

                        soft =
                            child dir "soft.txt"
                    in
                    Task.sequence
                        [ attempt Path.filenameWithExtension
                            (file (File.writeFile (bytes "data") target |> Task.andThen (\_ -> File.hardLink hard target)))
                            |> label "hardlink"
                        , attempt fromBytes (file (File.readFile hard)) |> label "hardlink-content"
                        , attempt Path.filenameWithExtension (file (File.hardLink hard target)) |> label "hardlink-exists"
                        , attempt Path.filenameWithExtension (file (File.softLink soft (Path.fromPosixString "target.txt")))
                            |> label "softlink"
                        , attempt Path.toPosixString (file (File.readLink soft)) |> label "readlink"
                        , attempt Path.toPosixString (file (File.readLink target)) |> label "readlink-not-link"
                        , attempt fromBytes (file (File.readFile soft)) |> label "softlink-content"
                        , attempt (.entityType >> entityName) (file (File.metadata { resolveLink = False } soft))
                            |> label "lstat-softlink"
                        , attempt (.entityType >> entityName) (file (File.metadata { resolveLink = True } soft))
                            |> label "stat-softlink"
                        , attempt
                            (\( a, b ) ->
                                if Path.toPosixString a == Path.toPosixString b then
                                    "True"

                                else
                                    "False " ++ Path.toPosixString a ++ " " ++ Path.toPosixString b
                            )
                            (file (Task.map2 Tuple.pair (File.realPath soft) (File.realPath target)))
                            |> label "realpath-softlink"
                        , attempt (\_ -> "")
                            (file
                                (File.softLink (child dir "dangling") (Path.fromPosixString "no-such-target")
                                    |> Task.andThen (File.metadata { resolveLink = True })
                                )
                            )
                            |> label "dangling-stat"
                        , attempt (.entityType >> entityName) (file (File.metadata { resolveLink = False } (child dir "dangling")))
                            |> label "dangling-lstat"
                        , FileTestHelp.rawError
                            (\e ->
                                if File.errorIsLinkLoop e then
                                    "True"

                                else
                                    "False " ++ File.errorCode e
                            )
                            (File.softLink (child dir "loop-a") (Path.fromPosixString "loop-b")
                                |> Task.andThen (\_ -> File.softLink (child dir "loop-b") (Path.fromPosixString "loop-a"))
                                |> Task.andThen (\_ -> File.readFile (child dir "loop-a"))
                            )
                            |> label "loop"
                        , attempt
                            (List.map (.path >> Path.filenameWithExtension) >> String.join "," >> (\s -> "[" ++ s ++ "]"))
                            (file
                                (File.unlink soft
                                    |> Task.andThen (\_ -> File.unlink (child dir "dangling"))
                                    |> Task.andThen (\_ -> File.unlink (child dir "loop-a"))
                                    |> Task.andThen (\_ -> File.unlink (child dir "loop-b"))
                                    |> Task.andThen (\_ -> File.listDirectory dir)
                                )
                            )
                            |> label "unlink-links"
                        ]
                )
        )
