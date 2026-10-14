module Ls exposing (main)

{-| `ls`: list the directory named on the command line (or the current directory), one entry per
line, with a trailing `/` on directories.

    eco make src/Ls.elm --output=ls && ./ls /tmp

-}

import Stream.Log
import System
import System.File as File
import System.File.Path as Path exposing (Path)
import Task exposing (Task)


main : System.SimpleProgram msg
main =
    System.defineSimpleProgram (\env -> System.endSimpleProgram (run env))


run : System.Environment -> Task Never ()
run env =
    directory env
        |> Task.andThen File.listDirectory
        |> Task.map (List.map entryName >> List.sort >> String.join "\n")
        |> Task.andThen (Stream.Log.line env.stdout)
        |> Task.onError
            (\err ->
                Stream.Log.line env.stderr ("ls: " ++ File.errorToString err)
                    |> Task.andThen (\_ -> System.setExitCode 1)
            )


directory : System.Environment -> Task File.Error Path
directory env =
    -- args includes the program name first (the full C argv).
    case List.drop 1 env.args of
        dir :: _ ->
            Task.succeed (Path.fromPosixString dir)

        [] ->
            File.currentWorkingDirectory


entryName : { path : Path, entityType : File.EntityType } -> String
entryName entry =
    Path.filenameWithExtension entry.path
        ++ (if entry.entityType == File.Directory then
                "/"

            else
                ""
           )
