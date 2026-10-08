module SocketTcpConnectToHostTest exposing (main)

{-| `Socket.Tcp.connectToHost` (plans/eco-system-sockets.md §D.2): an address literal is used as
is; a name is resolved and its addresses are tried in order, so `localhost` reaches a listener
bound only to `127.0.0.1` even where `::1` comes first; a name that does not exist fails with a
host-not-found error.
-}

-- CHECK: literal: inet 127.0.0.1
-- CHECK: localhost: inet 127.0.0.1
-- CHECK: invalid name: host not found True
-- EXIT: 0

import Socket
import Socket.Tcp
import SocketTestHelp as H
import System
import Task exposing (Task)


remoteOf : Task Socket.Error Socket.Connection -> Task String String
remoteOf connect =
    H.socketErr connect
        |> Task.andThen
            (\c ->
                Socket.close c |> Task.map (\_ -> H.endpointToString (Socket.remoteEndpoint c))
            )


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr H.listenLocal
                |> Task.andThen
                    (\listener ->
                        let
                            p =
                                H.portOf listener
                        in
                        remoteOf (Socket.Tcp.connectToHost "127.0.0.1" p)
                            |> Task.andThen
                                (\literal ->
                                    remoteOf (Socket.Tcp.connectToHost "localhost" p)
                                        |> Task.andThen
                                            (\local ->
                                                Socket.Tcp.connectToHost "no-such-host.invalid" p
                                                    |> Task.map (\_ -> "connected?!")
                                                    |> Task.onError (\e -> Task.succeed ("host not found " ++ H.boolString (Socket.errorIsHostNotFound e)))
                                                    |> Task.andThen
                                                        (\invalid ->
                                                            H.socketErr (Socket.closeListener listener)
                                                                |> Task.map
                                                                    (\_ ->
                                                                        [ "literal: " ++ literal
                                                                        , "localhost: " ++ local
                                                                        , "invalid name: " ++ invalid
                                                                        ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
