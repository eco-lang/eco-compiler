module SocketTlsInfoTest exposing (main)

{-| `Socket.Tls.info` (plans/eco-system-sockets.md Appendix B.3): on a plain TCP connection it fails
with `EINVAL`; on a TLS connection it reports what the handshake agreed on, on both ends.
-}

-- CHECK: plain tcp client: err EINVAL
-- CHECK: plain tcp server: err EINVAL
-- CHECK: tls client: TLSv1.3 alpn none
-- CHECK: tls server: TLSv1.3 alpn none
-- EXIT: 0

import Socket
import Socket.Tls
import SocketTestHelp as H
import SocketTlsHelp as T
import System
import Task exposing (Task)


describeInfo : Task Socket.Error Socket.Tls.Info -> Task x String
describeInfo task =
    task
        |> Task.map (\info -> info.protocol ++ " alpn " ++ T.alpnString info.alpn)
        |> Task.onError (\e -> Task.succeed ("err " ++ Socket.errorCode e))


{-| Connect with `connect`, accept the other end, describe both ends' info, close everything.
-}
pair : Task Socket.Error Socket.Listener -> (Socket.Listener -> Task Socket.Error Socket.Connection) -> Task String ( String, String )
pair listen connect =
    H.socketErr listen
        |> Task.andThen
            (\listener ->
                H.async (H.socketErr (Socket.accept listener))
                    |> Task.andThen
                        (\accepted ->
                            H.socketErr (connect listener)
                                |> Task.andThen (\client -> accepted |> Task.map (\server -> ( client, server )))
                        )
                    |> Task.andThen
                        (\( client, server ) ->
                            describeInfo (Socket.Tls.info client)
                                |> Task.andThen
                                    (\c ->
                                        describeInfo (Socket.Tls.info server)
                                            |> Task.map (\s -> ( c, s ))
                                    )
                                |> Task.andThen
                                    (\r ->
                                        Socket.close client
                                            |> Task.andThen (\_ -> Socket.close server)
                                            |> Task.andThen (\_ -> H.socketErr (Socket.closeListener listener))
                                            |> Task.map (\_ -> r)
                                    )
                        )
            )


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            pair H.listenLocal H.connectTo
                |> Task.andThen
                    (\( plainClient, plainServer ) ->
                        pair (T.listenTls (T.server [])) (T.connectTls (T.trusted "localhost" []))
                            |> Task.map
                                (\( tlsClient, tlsServer ) ->
                                    [ "plain tcp client: " ++ plainClient
                                    , "plain tcp server: " ++ plainServer
                                    , "tls client: " ++ tlsClient
                                    , "tls server: " ++ tlsServer
                                    ]
                                )
                    )
        )
