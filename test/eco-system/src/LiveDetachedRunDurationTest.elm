module LiveDetachedRunDurationTest exposing (main)

{-| A Detached child holds nothing, but its `runDuration` timer does, on both backends
(plans/program-liveness-rule.md X4): the program spawns a Detached `sleep 30` with a 300 ms
limit and does nothing else, so its event loop is first empty only once the limit has expired
and the child has been told to stop. `onEmptyEventLoop` measures that moment. (The child's
`onExit` may or may not arrive before the program ends: after the limit nothing holds.)
-}

-- CHECK: waited: True
-- EXIT: 0

import ChildProcess as P
import System
import Task
import Time


type Msg
    = Started Time.Posix
    | Exited
    | Empty
    | Ended Time.Posix


main : Platform.Program System.Environment Int Msg
main =
    Platform.worker
        { init = \_ -> ( 0, Task.perform Started Time.now )
        , update =
            \msg t0 ->
                case msg of
                    Started t ->
                        ( Time.posixToMillis t
                        , P.spawn "sleep"
                            [ "30" ]
                            (P.defaultSpawnOptions (P.Detached (\_ -> Exited)) (\_ -> Exited)
                                |> (\o -> { o | shell = P.NoShell, runDuration = P.Milliseconds 300 })
                            )
                        )

                    Exited ->
                        ( t0, Cmd.none )

                    Empty ->
                        ( t0, Task.perform Ended Time.now )

                    Ended t ->
                        let
                            _ =
                                Debug.log "waited" (Time.posixToMillis t - t0 >= 280)
                        in
                        ( t0, Cmd.none )
        , subscriptions = \_ -> System.onEmptyEventLoop Empty
        }
