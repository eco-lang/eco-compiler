module Ls exposing (main)

{-| `ls`: list the directory named on the command line (or the current directory), one entry per
line, with a trailing `/` on directories.

    eco make src/Ls.elm --output=ls && ./ls /tmp

-}

import FileSystem
import Stream
import System
import Path exposing (Path)
import Task exposing (Task)


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram run


run : System.Environment -> Task Never ()
run env =
    directory env
        |> Task.andThen FileSystem.listDirectory
        |> Task.map (List.map entryName >> List.sort >> String.join "\n")
        |> Task.andThen (\listing -> Stream.logLine listing env.stdout)
        |> Task.onError
            (\err ->
                Stream.logLine ("ls: " ++ FileSystem.errorToString err) env.stderr
                    |> Task.andThen (\_ -> System.setExitCode 1)
            )


directory : System.Environment -> Task FileSystem.Error Path
directory env =
    -- args includes the program name first (the full C argv).
    case List.drop 1 env.args of
        dir :: _ ->
            Task.succeed (Path.fromPosixString dir)

        [] ->
            FileSystem.currentWorkingDirectory


entryName : { path : Path, entityType : FileSystem.EntityType } -> String
entryName entry =
    Path.filenameWithExtension entry.path
        ++ (if entry.entityType == FileSystem.Directory then
                "/"

            else
                ""
           )
