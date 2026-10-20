module SystemProgramTest exposing (main)

{-| A program made with `System.program` gets the `Environment` as its flags, runs its update,
and ends with exit status 0 once it has no work left.
-}

-- CHECK: init
-- CHECK: update
-- EXIT: 0

import Stream
import System
import Task


type Msg
    = Started
    | Done


main : Platform.Program System.Environment System.Environment Msg
main =
    System.program
        { init = \env -> ( env, Task.perform (\_ -> Started) (Stream.logLine "init" env.stdout) )
        , update =
            \msg env ->
                case msg of
                    Started ->
                        ( env, Task.perform (\_ -> Done) (Stream.logLine "update" env.stdout) )

                    Done ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
