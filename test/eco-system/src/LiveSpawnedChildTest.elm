module LiveSpawnedChildTest exposing (main)

{-| A spawned child that is not Detached holds until its exit is published
(plans/program-liveness-rule.md X5, L4): the program spawns `sleep 0.3` with `Ignored` stdio and
does nothing else. The child keeps the program running until it exits, and the `onExit` message
logs `exit 0`; then nothing holds and the program ends.
-}

-- CHECK: exit 0
-- EXIT: 0

import ChildProcess as P
import LiveTestHelp as L
import System


type Msg
    = Started
    | Exited Int
    | Logged


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init =
            \env ->
                ( env
                , P.spawn "sleep"
                    [ "0.3" ]
                    (P.defaultSpawnOptions (P.Ignored (\_ -> Started)) Exited
                        |> (\o -> { o | shell = P.NoShell })
                    )
                )
        , update =
            \msg env ->
                case msg of
                    Started ->
                        ( env, Cmd.none )

                    Exited code ->
                        ( env, L.log env Logged ("exit " ++ String.fromInt code) )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
