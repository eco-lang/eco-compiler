module SocketTcpRefusedTest exposing (main)

{-| Connecting to a port nobody listens on (the harness's free `ECO_TEST_PORT`) fails with
kind `ConnectionRefused` (`ECONNREFUSED`, plans/eco-system-sockets.md §D.5), and the message
names the address, as Node's does.
-}

-- CHECK: kind: ConnectionRefused
-- CHECK: message: ECONNREFUSED: connect ECONNREFUSED 127.0.0.1:{{[0-9]+}}
-- EXIT: 0

import ErrorNames
import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import SocketTestHelp as H
import System
import Task


main : Platform.Program System.Environment () ()
main =
    H.program
        (\_ ->
            H.testPort
                |> Task.andThen
                    (\p ->
                        Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) p)
                            |> Task.map (\_ -> [ "connected?!" ])
                            |> Task.onError
                                (\e ->
                                    Task.succeed
                                        [ "kind: " ++ ErrorNames.socketError e
                                        , "message: " ++ Socket.errorToString e
                                        ]
                                )
                    )
        )
