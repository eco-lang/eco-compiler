module SocketTcpTimeoutTest exposing (main)

-- SKIP-JS: Node accepts connections eagerly, so a listener's queue never fills (plans/eco-system-sockets.md Appendix E)

{-| The connect timeout (plans/eco-system-sockets.md §3.3.3 "Connect"): a listener with backlog 1
that never accepts has its queue filled by a few connections; a further connect with
`timeout = Just 300` fails with `ETIMEDOUT` (`errorIsTimedOut`) after about 300 ms. A second such
connect without a timeout is killed with `Process.kill` (the T7 kill handle aborts it), and the
program then exits by itself once the listener is closed: nothing is left waiting.
-}

-- CHECK: timed out: ETIMEDOUT True
-- CHECK: prompt: True
-- CHECK: killed connect: done
-- CHECK-NOT: killed connect completed
-- EXIT: 0

import Process
import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import SocketTestHelp as H
import Stream.Log
import System
import Task exposing (Task)
import Time


now : Task x Int
now =
    Time.now |> Task.map Time.posixToMillis


connectWithTimeout : Int -> Int -> Task Socket.Error Socket.Connection
connectWithTimeout p ms =
    let
        d =
            Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) p
    in
    Socket.Tcp.connect { d | timeout = Just ms }


{-| Connect until an attempt times out (the queue is full); at most `n` attempts. Successful
connections are kept open (they fill the queue).
-}
fill : Int -> Int -> List Socket.Connection -> Task String ( Socket.Error, Int, List Socket.Connection )
fill p n kept =
    if n <= 0 then
        Task.fail "the listener queue never filled"

    else
        now
            |> Task.andThen
                (\t0 ->
                    connectWithTimeout p 300
                        |> Task.map Ok
                        |> Task.onError (\e -> Task.succeed (Err e))
                        |> Task.andThen
                            (\r ->
                                case r of
                                    Ok conn ->
                                        fill p (n - 1) (conn :: kept)

                                    Err e ->
                                        now |> Task.map (\t1 -> ( e, t1 - t0, kept ))
                            )
                )


main : System.SimpleProgram ()
main =
    H.program
        (\env ->
            Socket.Tcp.listen
                (let
                    d =
                        Socket.Tcp.defaultListenOptions (Address.loopback IPv4) 0
                 in
                 { d | backlog = 1 }
                )
                |> H.socketErr
                |> Task.andThen
                    (\listener ->
                        fill (H.portOf listener) 20 []
                            |> Task.andThen
                                (\( err, elapsed, kept ) ->
                                    Process.spawn
                                        (Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) (H.portOf listener))
                                            |> Task.andThen (\_ -> Stream.Log.line env.stdout "killed connect completed")
                                            |> Task.onError (\_ -> Stream.Log.line env.stdout "killed connect completed with an error")
                                        )
                                        |> Task.andThen (\pid -> Process.sleep 100 |> Task.andThen (\_ -> Process.kill pid))
                                        |> Task.andThen (\_ -> Task.sequence (List.map Socket.close kept))
                                        |> Task.andThen (\_ -> H.socketErr (Socket.closeListener listener))
                                        |> Task.map
                                            (\_ ->
                                                [ "timed out: " ++ Socket.errorCode err ++ " " ++ H.boolString (Socket.errorIsTimedOut err)
                                                , "prompt: " ++ H.boolString (elapsed >= 250 && elapsed < 2000)
                                                , "killed connect: done"
                                                ]
                                            )
                                )
                    )
        )
