module SocketTcpRefusedTest exposing (main)

{-| Connecting to a port nobody listens on (the harness's free `ECO_TEST_PORT`) fails with
`ECONNREFUSED` (plans/eco-system-sockets.md §D.5): `errorIsConnectionRefused` holds and the
message names the address, as Node's does.
-}

-- CHECK: code: ECONNREFUSED
-- CHECK: refused: True
-- CHECK: message: ECONNREFUSED: connect ECONNREFUSED 127.0.0.1:{{[0-9]+}}
-- EXIT: 0

import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import SocketTestHelp as H
import System
import Task


main : System.SimpleProgram ()
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
                                        [ "code: " ++ Socket.errorCode e
                                        , "refused: " ++ H.boolString (Socket.errorIsConnectionRefused e)
                                        , "message: " ++ Socket.errorToString e
                                        ]
                                )
                    )
        )
