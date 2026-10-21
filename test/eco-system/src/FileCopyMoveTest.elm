module FileCopyMoveTest exposing (main)

{-| `FileSystem.copyFile` and `move` (plans/eco-system-library.md Phase 4
step 4.6, Appendix E.3): gren's argument order (`copyFile dest src`,
`move new old`), copy overwrites, both succeed with the destination and report
the destination in `errorPath`; `realPath` of a relative path is absolute.
-}

-- CHECK: copy: ok dst.txt
-- CHECK: copy-content: ok one
-- CHECK: copy-overwrite: ok two
-- CHECK: copy-src-unchanged: ok two
-- CHECK: copy-missing-src: err NoSuchFileOrDirectory @dst.txt
-- CHECK: copy-dir: err DirectoryFound @dst.txt
-- CHECK: move: ok moved.txt
-- CHECK: move-old-gone: err NoSuchFileOrDirectory @src.txt
-- CHECK: move-new-content: ok two
-- CHECK: move-missing: err NoSuchFileOrDirectory @target.txt
-- CHECK: move-dir: ok [inner.txt]
-- CHECK: realpath-dir: ok True
-- EXIT: 0

import FileSystem as File
import FileTestHelp exposing (attempt, bytes, child, file, fromBytes)
import Path
import System
import Task


label : String -> Task.Task x String -> Task.Task x String
label name =
    Task.map (\s -> name ++ ": " ++ s)


main : Platform.Program System.Environment () ()
main =
    FileTestHelp.program
        (\_ ->
            FileTestHelp.withTempDir
                (\dir ->
                    let
                        src =
                            child dir "src.txt"

                        dst =
                            child dir "dst.txt"

                        moved =
                            child dir "moved.txt"
                    in
                    Task.sequence
                        [ attempt Path.filenameWithExtension
                            (file (File.writeFile (bytes "one") src |> Task.andThen (\_ -> File.copyFile dst src)))
                            |> label "copy"
                        , attempt fromBytes (file (File.readFile dst)) |> label "copy-content"
                        , attempt fromBytes
                            (file
                                (File.writeFile (bytes "two") src
                                    |> Task.andThen (\_ -> File.copyFile dst src)
                                    |> Task.andThen File.readFile
                                )
                            )
                            |> label "copy-overwrite"
                        , attempt fromBytes (file (File.readFile src)) |> label "copy-src-unchanged"
                        , attempt Path.filenameWithExtension (file (File.copyFile dst (child dir "nope.txt")))
                            |> label "copy-missing-src"
                        , attempt Path.filenameWithExtension
                            (file (File.makeDirectory { recursive = False } (child dir "adir") |> Task.andThen (File.copyFile dst)))
                            |> label "copy-dir"
                        , attempt Path.filenameWithExtension (file (File.move moved src)) |> label "move"
                        , attempt fromBytes (file (File.readFile src)) |> label "move-old-gone"
                        , attempt fromBytes (file (File.readFile moved)) |> label "move-new-content"
                        , attempt Path.filenameWithExtension (file (File.move (child dir "target.txt") (child dir "nope.txt")))
                            |> label "move-missing"
                        , attempt
                            (List.map (.path >> Path.filenameWithExtension) >> String.join "," >> (\s -> "[" ++ s ++ "]"))
                            (file
                                (File.makeDirectory { recursive = False } (child dir "d1")
                                    |> Task.andThen (\d1 -> File.writeFile (bytes "x") (child d1 "inner.txt"))
                                    |> Task.andThen (\_ -> File.move (child dir "d2") (child dir "d1"))
                                    |> Task.andThen File.listDirectory
                                )
                            )
                            |> label "move-dir"
                        , attempt
                            (\real -> boolString (Path.toPosixString real == Path.toPosixString dir || String.endsWith (Path.filenameWithExtension dir) (Path.toPosixString real)))
                            (file (File.realPath dir))
                            |> label "realpath-dir"
                        ]
                )
        )


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"
