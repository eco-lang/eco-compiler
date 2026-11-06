module Cat exposing (main)

{-| `cat`: copy each file named on the command line to stdout, or stdin when no file is named.

    eco make src/Cat.elm --output=cat && ./cat README.md

-}

import FileSystem
import Stream
import System
import Path
import Task exposing (Task)


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram run


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
    FileSystem.readFile (Path.fromPosixString path)
        |> Task.andThen (\contents -> Stream.log contents env.stdout)
        |> Task.onError (\err -> fail env ("cat: " ++ FileSystem.errorToString err))


fail : System.Environment -> String -> Task Never ()
fail env message =
    Stream.logLine message env.stderr
        |> Task.andThen (\_ -> System.setExitCode 1)
