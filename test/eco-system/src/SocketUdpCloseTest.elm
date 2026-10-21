module SocketUdpCloseTest exposing (main)

{-| `Socket.Udp.close` (plans/eco-system-sockets.md §3.4, Appendix B.2): a parked `receive` fails
with kind `Cancelled` (`ECANCELED`); closing twice is fine; `receive` and `send` on a closed
socket fail the same way; the program then exits by itself (a closed socket no longer keeps it
running).
-}

-- CHECK: parked receive: Cancelled
-- CHECK: receive after close: err Cancelled
-- CHECK: send after close: err Cancelled
-- CHECK: closed twice: ok
-- EXIT: 0

import ErrorNames
import Process
import Socket
import Socket.Udp
import SocketTestHelp as H
import SocketUdpTestHelp as U
import System
import Task


main : Platform.Program System.Environment () ()
main =
    H.program
        (\_ ->
            H.socketErr U.bindLocal
                |> Task.andThen
                    (\socket ->
                        H.async
                            (Socket.Udp.receive socket
                                |> Task.map (\_ -> "received?!")
                                |> Task.onError (\e -> Task.succeed (ErrorNames.socketError e))
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
