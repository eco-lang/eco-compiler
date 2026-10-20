module LiveDetachedChildTest exposing (main)

{-| A Detached child holds nothing (plans/program-liveness-rule.md X4, L4, LIVE_002): the program
spawns a Detached `sleep 120`, logs `spawned` and ends at once, while the child still runs. A
Detached child that held would keep it running for 120 s (killed by the watchdog).
-}

-- CHECK: spawned
-- EXIT: 0

import ChildProcess as P
import LiveTestHelp as L
import System


type Msg
    = Started
    | Exited
    | Logged


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init =
            \env ->
                ( env
                , P.spawn "sleep"
                    [ "120" ]
                    (P.defaultSpawnOptions (P.Detached (\_ -> Started)) (\_ -> Exited)
                        |> (\o -> { o | shell = P.NoShell })
                    )
                )
        , update =
            \msg env ->
                case msg of
                    Started ->
                        ( env, L.log env Logged "spawned" )

                    Exited ->
                        ( env, Cmd.none )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
