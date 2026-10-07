module ProcessSpawnIntegratedTest exposing (main)

{-| `spawn` with an `Integrated` connection (plans/eco-system-library.md
Phase 5 step 5.4): the child writes straight to the program's stdout and
stderr, the connection message arrives first, then `onExit` with the exit
code. Ignored and Detached children are spawned as well: their output goes
to /dev/null, and the Detached one (a long sleep) does not keep the program
alive, so the test ends promptly.
-}

-- CHECK: integrated-child-stdout
-- CHECK: integrated-child-stderr
-- CHECK-NOT: ignored-child-output
-- CHECK: started: integrated
-- CHECK: started: ignored
-- CHECK: started: detached
-- CHECK: integrated exit: 5
-- CHECK: ignored exit: 0
-- CHECK-NOT: detached exit
-- EXIT: 0

import Process
import Stream.Log
import System
import System.Process as P
import Task


type Msg
    = Started String
    | Exited String Int
    | Logged


log : System.Environment -> String -> Cmd Msg
log env line =
    Task.perform (\_ -> Logged) (Stream.Log.line env.stdout line)


main : System.Program System.Environment Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( env
                , Cmd.batch
                    [ P.spawn "echo integrated-child-stdout; echo integrated-child-stderr >&2; exit 5"
                        []
                        (P.defaultSpawnOptions (P.Integrated (\_ -> Started "integrated")) (Exited "integrated"))
                    , P.spawn "echo"
                        [ "ignored-child-output" ]
                        (P.defaultSpawnOptions (P.Ignored (\_ -> Started "ignored")) (Exited "ignored"))
                    , P.spawn "sleep"
                        [ "30" ]
                        (P.defaultSpawnOptions (P.Detached (\_ -> Started "detached")) (Exited "detached"))
                    ]
                )
        , update =
            \msg env ->
                case msg of
                    Started name ->
                        ( env, log env ("started: " ++ name) )

                    Exited name code ->
                        ( env, log env (name ++ " exit: " ++ String.fromInt code) )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
