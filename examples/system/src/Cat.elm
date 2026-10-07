module Cat exposing (main)

{-| `cat`: copy each file named on the command line to stdout, or stdin when no file is named.

    eco make src/Cat.elm --output=cat && ./cat README.md

-}

import Stream
import Stream.Log
import System
import System.File as File
import System.File.Path as Path
import Task exposing (Task)


main : System.SimpleProgram msg
main =
    System.defineSimpleProgram (\env -> System.endSimpleProgram (run env))


run : System.Environment -> Task Never ()
run env =
    -- args includes the program name first (the full C argv).
    case List.drop 1 env.args of
        [] ->
            Stream.pipeTo env.stdout env.stdin
                |> Task.onError (\err -> fail env ("cat: stdin: " ++ Stream.errorToString err))

        paths ->
            paths
                |> List.map (catFile env)
                |> Task.sequence
                |> Task.map (\_ -> ())


catFile : System.Environment -> String -> Task Never ()
catFile env path =
    File.readFile (Path.fromPosixString path)
        |> Task.andThen (Stream.Log.bytes env.stdout)
        |> Task.onError (\err -> fail env ("cat: " ++ File.errorToString err))


fail : System.Environment -> String -> Task Never ()
fail env message =
    Stream.Log.line env.stderr message
        |> Task.andThen (\_ -> System.setExitCode 1)
