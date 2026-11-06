module Nl exposing (main)

{-| `nl`: number the lines read from stdin, one at a time with `Stream.readLine`.

    eco make src/Nl.elm --output=nl && printf 'one\ntwo\n' | ./nl

-}

import Stream
import System
import Task exposing (Task)


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\env -> numberLines env 1)


{-| Read a line, print it with its number, and go on until stdin is closed.
-}
numberLines : System.Environment -> Int -> Task Never ()
numberLines env n =
    nextLine env
        |> Task.andThen
            (\maybeLine ->
                case maybeLine of
                    Just line ->
                        Stream.logLine (String.padLeft 6 ' ' (String.fromInt n) ++ "  " ++ line) env.stdout
                            |> Task.andThen (\_ -> numberLines env (n + 1))

                    Nothing ->
                        Task.succeed ()
            )


{-| The next line of stdin, or `Nothing` at its end (or after reporting a read error).
-}
nextLine : System.Environment -> Task Never (Maybe String)
nextLine env =
    Stream.readLine env.stdin
        |> Task.map Just
        |> Task.onError
            (\err ->
                case err of
                    Stream.Closed ->
                        Task.succeed Nothing

                    _ ->
                        Stream.logLine ("nl: " ++ Stream.errorToString err) env.stderr
                            |> Task.andThen (\_ -> System.setExitCode 1)
                            |> Task.map (\_ -> Nothing)
            )
