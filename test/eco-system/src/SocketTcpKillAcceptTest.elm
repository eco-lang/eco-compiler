module SocketTcpKillAcceptTest exposing (main)

{-| Killing a parked `Socket.accept` (plans/eco-system-sockets.md §3.3.8, T7): the killed task never
completes, its credit is returned, and a later `accept` still gets the next client.
-}

-- CHECK: after kill: next client
-- CHECK-NOT: killed accept completed
-- EXIT: 0

import Process
import Socket
import SocketTestHelp as H
import Stream
import System
import Task


main : Platform.Program System.Environment () ()
main =
    H.program
        (\env ->
            H.socketErr H.listenLocal
                |> Task.andThen
                    (\listener ->
                        Process.spawn
                            (Socket.accept listener
                                |> Task.andThen (\_ -> Stream.logLine "killed accept completed" env.stdout)
                                |> Task.onError (\_ -> Stream.logLine "killed accept completed with an error" env.stdout)
                            )
                            |> Task.andThen (\pid -> Process.sleep 100 |> Task.andThen (\_ -> Process.kill pid))
                            |> Task.andThen (\_ -> H.async (H.acceptRead listener))
                            |> Task.andThen
                                (\accepted ->
                                    Process.sleep 50
                                        |> Task.andThen (\_ -> H.socketErr (H.connectTo listener))
                                        |> Task.andThen (\c -> H.streamErr (H.writeAll "next client" (Socket.writable c)))
                                        |> Task.andThen (\_ -> accepted)
                                )
                            |> Task.andThen
                                (\got ->
                                    H.socketErr (Socket.closeListener listener)
                                        |> Task.map (\_ -> [ "after kill: " ++ got ])
                                )
                    )
        )
