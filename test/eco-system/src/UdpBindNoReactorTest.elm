module UdpBindNoReactorTest exposing (main)

{-| SOCK-15 (plans/kernel-lib-bug-fixes.md, fix group 17): a UDP socket the reactor refused never reads.

`ECO_IOR_FAIL_INIT_FOR_TEST=1` (a test hook in system-kernel-cpp/src/eco-system/Core/IoReactor.cpp,
debug/test builds only) makes the IoReactor singleton's construction fail as though the event
loop could not be created, so `ok` stays false for the life of the process. The UDP bind
(`udpBindBody`, Socket/Udp.cpp) checks `socketIoAvailable` and fails at once with ENOSYS ("bind
failed: ..."), so the program exits 0. Before the fix the bind succeeded, the socket's handler was
never watched, and a `receive` parked forever (the watchdog logged "receive parked" and exited 3).
-}

-- LINUX-ONLY: the reactor hook is POSIX-only (on Windows the UDP bind already fails with ENOTSUP)
-- SKIP-JS: the IoReactor init-failure hook exists only in the native runtime
-- ENV: ECO_IOR_FAIL_INIT_FOR_TEST=1
-- CHECK: UdpBindNoReactorTest: bind failed: ENOSYS
-- CHECK-NOT: UdpBindNoReactorTest: bind ok
-- CHECK-NOT: receive parked
-- EXIT: 0

import Process
import Socket
import Socket.Udp as Udp
import Stream
import SocketUdpTestHelp as U
import System
import Task


type Msg
    = Bound (Result Socket.Error Udp.Socket)
    | Received (Result String String)
    | Watchdog
    | Exit Int


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init = \env -> ( env, Task.attempt Bound U.bindLocal )
        , update =
            \msg env ->
                let
                    log line next =
                        Task.perform (\_ -> next) (Stream.logLine ("UdpBindNoReactorTest: " ++ line) env.stdout)
                in
                case msg of
                    Bound (Err e) ->
                        ( env, log ("bind failed: " ++ Socket.errorToString e) (Exit 0) )

                    Bound (Ok s) ->
                        ( env
                        , Cmd.batch
                            [ Stream.logLine "UdpBindNoReactorTest: bind ok" env.stdout
                                |> Task.andThen (\_ -> U.sendText (Udp.localEndpoint s) "ping" s)
                                |> Task.andThen (\_ -> U.receiveText s)
                                |> Task.map Tuple.first
                                |> Task.attempt Received
                            , Task.perform (\_ -> Watchdog) (Process.sleep 2000)
                            ]
                        )

                    Received (Ok text) ->
                        ( env, log ("received " ++ text) (Exit 0) )

                    Received (Err e) ->
                        ( env, log ("send/receive failed: " ++ e) (Exit 0) )

                    Watchdog ->
                        ( env, log "receive parked after 2 s" (Exit 3) )

                    Exit code ->
                        ( env, System.exitWithCode code )
        , subscriptions = \_ -> Sub.none
        }
