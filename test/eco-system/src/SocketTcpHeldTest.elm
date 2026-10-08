module SocketTcpHeldTest exposing (main)

{-| Undelivered connections are held, never dropped (plans/eco-system-sockets.md SD14, §3.4): a
client connects and sends before anyone accepts or subscribes; a later `Socket.accept` gets that
connection and its data.
-}

-- CHECK: client sent: ok
-- CHECK: later accept got: early bird
-- EXIT: 0

import Process
import Socket
import SocketTestHelp as H
import System
import Task


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr H.listenLocal
                |> Task.andThen
                    (\listener ->
                        H.socketErr (H.connectTo listener)
                            |> Task.andThen (\conn -> H.streamErr (H.writeAll "early bird" (Socket.writable conn)))
                            |> Task.andThen (\_ -> Process.sleep 200)
                            |> Task.andThen (\_ -> H.acceptRead listener)
                            |> Task.andThen
                                (\got ->
                                    H.socketErr (Socket.closeListener listener)
                                        |> Task.map (\_ -> [ "client sent: ok", "later accept got: " ++ got ])
                                )
                    )
        )
