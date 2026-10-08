module SocketUdpCloseTest exposing (main)

{-| `Socket.Udp.close` (plans/eco-system-sockets.md §3.4, Appendix B.2): a parked `receive` fails
with `ECANCELED` (`errorIsCancelled`); closing twice is fine; `receive` and `send` on a closed
socket fail with `ECANCELED`; the program then exits by itself (a closed socket no longer keeps it
running).
-}

-- CHECK: parked receive: ECANCELED cancelled True
-- CHECK: receive after close: err ECANCELED
-- CHECK: send after close: err ECANCELED
-- CHECK: closed twice: ok
-- EXIT: 0

import Process
import Socket
import Socket.Udp
import SocketTestHelp as H
import SocketUdpTestHelp as U
import System
import Task


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr U.bindLocal
                |> Task.andThen
                    (\socket ->
                        H.async
                            (Socket.Udp.receive socket
                                |> Task.map (\_ -> "received?!")
                                |> Task.onError (\e -> Task.succeed (Socket.errorCode e ++ " cancelled " ++ H.boolString (Socket.errorIsCancelled e)))
                            )
                            |> Task.andThen
                                (\parked ->
                                    Process.sleep 50
                                        |> Task.andThen (\_ -> Socket.Udp.close socket)
                                        |> Task.andThen (\_ -> Socket.Udp.close socket)
                                        |> Task.andThen (\_ -> parked)
                                        |> Task.andThen
                                            (\parkedResult ->
                                                H.describe (Socket.Udp.receive socket)
                                                    |> Task.andThen
                                                        (\afterReceive ->
                                                            H.describe (Socket.Udp.send (Socket.Udp.localEndpoint socket) (H.bytesOf "x") socket)
                                                                |> Task.map
                                                                    (\afterSend ->
                                                                        [ "parked receive: " ++ parkedResult
                                                                        , "receive after close: " ++ afterReceive
                                                                        , "send after close: " ++ afterSend
                                                                        , "closed twice: ok"
                                                                        ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
