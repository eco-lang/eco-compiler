module FileSpecialPathsTest exposing (main)

{-| The four special-path getters (plans/eco-system-library.md Phase 4 step
4.6, Appendix E.3, S mode): `homeDirectory`, `currentWorkingDirectory`,
`tmpDirectory` (an existing directory) and `devNull`, which swallows writes
and reads as empty.
-}

-- CHECK: home: True
-- CHECK: cwd-absolute: True
-- CHECK: cwd-is-dir: ok Directory
-- CHECK: tmp-is-dir: ok Directory
-- CHECK: devnull: /dev/null
-- CHECK: devnull-write: ok
-- CHECK: devnull-read: ok 0
-- EXIT: 0

import Bytes
import FileTestHelp exposing (attempt, bytes, file)
import System
import System.File as File
import System.File.Path as Path
import Task exposing (Task)


label : String -> Task x String -> Task x String
label name =
    Task.map (\s -> name ++ ": " ++ s)


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


isDir : File.Metadata -> String
isDir m =
    if m.entityType == File.Directory then
        "Directory"

    else
        "Other"


main : System.SimpleProgram ()
main =
    FileTestHelp.program
        (\_ ->
            Task.sequence
                [ File.homeDirectory |> Task.map (\p -> boolString (Path.toPosixString p /= ".")) |> label "home"
                , File.currentWorkingDirectory
                    |> Task.map (\p -> boolString (String.startsWith "/" (Path.toPosixString p)))
                    |> label "cwd-absolute"
                , attempt isDir (file (File.currentWorkingDirectory |> Task.andThen (File.metadata { resolveLink = True })))
                    |> label "cwd-is-dir"
                , attempt isDir (file (File.tmpDirectory |> Task.andThen (File.metadata { resolveLink = True })))
                    |> label "tmp-is-dir"
                , File.devNull |> Task.map Path.toPosixString |> label "devnull"
                , attempt (\_ -> "") (file (File.devNull |> Task.andThen (File.writeFile (bytes "discard me"))))
                    |> label "devnull-write"
                , attempt (Bytes.width >> String.fromInt) (file (File.devNull |> Task.andThen File.readFile))
                    |> label "devnull-read"
                ]
        )
