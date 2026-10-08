module SocketTcpAcceptTaskTest exposing (main)

{-| A task-only TCP server (plans/eco-system-sockets.md §4 S3): two clients, one after the other,
each arrives through its own `Socket.accept`; the listener's endpoint reports the port the system
picked (not 0). The program closes its listener and exits by itself.
-}

-- CHECK: listener port nonzero: True
-- CHECK: accept 1: client one
-- CHECK: accept 2: client two
-- CHECK: closed: ok
-- EXIT: 0

import Process
import Socket
import SocketTestHelp as H
import System
import Task exposing (Task)


client : Socket.Listener -> String -> Task String ()
client listener text =
    H.socketErr (H.connectTo listener)
        |> Task.andThen (\conn -> H.streamErr (H.writeAll text (Socket.writable conn)))


one : Socket.Listener -> String -> Task String String
one listener text =
    H.async (H.acceptRead listener)
        |> Task.andThen
            (\accepted ->
                Process.sleep 50
                    |> Task.andThen (\_ -> client listener text)
                    |> Task.andThen (\_ -> accepted)
            )


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr H.listenLocal
                |> Task.andThen
                    (\listener ->
                        one listener "client one"
                            |> Task.andThen
                                (\first ->
                                    one listener "client two"
                                        |> Task.andThen
                                            (\second ->
                                                H.describe (Socket.closeListener listener)
                                                    |> Task.map
                                                        (\closed ->
                                                            [ "listener port nonzero: " ++ H.boolString (H.portOf listener /= 0)
                                                            , "accept 1: " ++ first
                                                            , "accept 2: " ++ second
                                                            , "closed: " ++ closed
                                                            ]
                                                        )
                                            )
                                )
                    )
        )
