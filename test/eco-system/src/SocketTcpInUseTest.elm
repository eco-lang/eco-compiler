module SocketTcpInUseTest exposing (main)

{-| A second listener on an address and port already listened on fails with `EADDRINUSE`
(plans/eco-system-sockets.md §D.5, `errorIsAddressInUse`); the first listener is unaffected and
the program exits once it is closed.
-}

-- CHECK: second listen: EADDRINUSE in use True
-- CHECK: first still accepts: hi
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
            H.socketErr H.listenLocal
                |> Task.andThen
                    (\first ->
                        Socket.Tcp.listen (Socket.Tcp.defaultListenOptions (Address.loopback IPv4) (H.portOf first))
                            |> Task.map (\_ -> "second listen: ok?!")
                            |> Task.onError
                                (\e ->
                                    Task.succeed
                                        ("second listen: "
                                            ++ Socket.errorCode e
                                            ++ " in use "
                                            ++ H.boolString (Socket.errorIsAddressInUse e)
                                        )
                                )
                            |> Task.andThen
                                (\line ->
                                    H.async (H.acceptRead first)
                                        |> Task.andThen
                                            (\accepted ->
                                                H.socketErr (H.connectTo first)
                                                    |> Task.andThen (\c -> H.streamErr (H.writeAll "hi" (Socket.writable c)))
                                                    |> Task.andThen (\_ -> accepted)
                                            )
                                        |> Task.andThen
                                            (\got ->
                                                H.socketErr (Socket.closeListener first)
                                                    |> Task.map (\_ -> [ line, "first still accepts: " ++ got ])
                                            )
                                )
                    )
        )
