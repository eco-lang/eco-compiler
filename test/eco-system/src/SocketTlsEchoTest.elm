module SocketTlsEchoTest exposing (main)

{-| TLS echo over loopback (plans/eco-system-sockets.md §4 S5): a TLS listener with the test CA's
`localhost` certificate and ALPN `["http/1.1"]`; a client trusting only the test CA, with server
name `localhost` and ALPN `["h2", "http/1.1"]`. Both ends agree on TLS 1.3 and `http/1.1`. The
client writes a 300 kB message and half-closes (`close_notify`, then FIN); the server reads to
`Closed`, then replies and half-closes; the client reads the reply to `Closed`. The program closes
its listener and exits by itself.
-}

-- CHECK: client protocol: TLSv1.3
-- CHECK: client alpn: http/1.1
-- CHECK: server protocol: TLSv1.3
-- CHECK: server alpn: http/1.1
-- CHECK: cipher named: True
-- CHECK: server got prefix: hello over tls|
-- CHECK: server got length: 300015
-- CHECK: client got echo intact: True
-- CHECK: client remote is the listener: True
-- CHECK: closed: ok
-- EXIT: 0

import Socket
import Socket.Tls
import SocketTestHelp as H
import SocketTlsHelp as T
import System
import Task exposing (Task)


message : String
message =
    "hello over tls|" ++ String.repeat 30000 "0123456789"


{-| Accept one connection, read it to `Closed`, reply `echo: <text>` and half-close.
-}
serve : Socket.Listener -> Task String ( String, Socket.Tls.Info )
serve listener =
    H.socketErr (Socket.accept listener)
        |> Task.andThen
            (\conn ->
                H.socketErr (Socket.Tls.info conn)
                    |> Task.andThen
                        (\info ->
                            H.streamErr (H.readAll (Socket.readable conn))
                                |> Task.andThen
                                    (\text ->
                                        H.streamErr (H.writeAll ("echo: " ++ text) (Socket.writable conn))
                                            |> Task.map (\_ -> ( text, info ))
                                    )
                        )
            )


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr (T.listenTls (T.server [ "http/1.1" ]))
                |> Task.andThen
                    (\listener ->
                        H.async (serve listener)
                            |> Task.andThen
                                (\served ->
                                    H.socketErr (T.connectTls (T.trusted "localhost" [ "h2", "http/1.1" ]) listener)
                                        |> Task.andThen
                                            (\client ->
                                                H.socketErr (Socket.Tls.info client)
                                                    |> Task.andThen
                                                        (\clientInfo ->
                                                            H.send message client
                                                                |> Task.andThen
                                                                    (\reply ->
                                                                        served
                                                                            |> Task.andThen
                                                                                (\( got, serverInfo ) ->
                                                                                    H.describe (Socket.closeListener listener)
                                                                                        |> Task.map
                                                                                            (\closed ->
                                                                                                [ "client protocol: " ++ clientInfo.protocol
                                                                                                , "client alpn: " ++ T.alpnString clientInfo.alpn
                                                                                                , "server protocol: " ++ serverInfo.protocol
                                                                                                , "server alpn: " ++ T.alpnString serverInfo.alpn
                                                                                                , "cipher named: " ++ H.boolString (clientInfo.cipher /= "" && clientInfo.cipher == serverInfo.cipher)
                                                                                                , "server got prefix: " ++ String.left 15 got
                                                                                                , "server got length: " ++ String.fromInt (String.length got)
                                                                                                , "client got echo intact: " ++ H.boolString (reply == "echo: " ++ message)
                                                                                                , "client remote is the listener: "
                                                                                                    ++ H.boolString (H.endpointToString (Socket.remoteEndpoint client) == H.endpointToString (Socket.listenerEndpoint listener))
                                                                                                , "closed: " ++ closed
                                                                                                ]
                                                                                            )
                                                                                )
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
