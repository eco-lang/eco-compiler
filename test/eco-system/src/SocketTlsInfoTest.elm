module SocketTlsInfoTest exposing (main)

{-| `Socket.Tls.info` (plans/eco-system-sockets.md Appendix B.3): on a plain TCP connection it fails
with `SocketError` of kind `InvalidInput` (`EINVAL`); on a TLS connection it reports what the handshake agreed on, on both ends.
-}

-- CHECK: plain tcp client: err SocketError InvalidInput
-- CHECK: plain tcp server: err SocketError InvalidInput
-- CHECK: tls client: Tls1_3 alpn none
-- CHECK: tls server: Tls1_3 alpn none
-- EXIT: 0

import ErrorNames
import Socket
import Socket.Tls
import SocketTestHelp as H
import SocketTlsHelp as T
import System
import Task exposing (Task)


versionString : Socket.Tls.TlsVersion -> String
versionString version =
    case version of
        Socket.Tls.Tls1_0 ->
            "Tls1_0"

        Socket.Tls.Tls1_1 ->
            "Tls1_1"

        Socket.Tls.Tls1_2 ->
            "Tls1_2"

        Socket.Tls.Tls1_3 ->
            "Tls1_3"

        Socket.Tls.UnknownTlsVersion name ->
            "UnknownTlsVersion " ++ name


describeInfo : Task Socket.Tls.Error Socket.Tls.Info -> Task x String
describeInfo task =
    task
        |> Task.map (\info -> versionString info.version ++ " alpn " ++ T.alpnString info.alpn)
        |> Task.onError (\e -> Task.succeed ("err " ++ ErrorNames.tlsError e))


{-| Connect with `connect`, accept the other end, describe both ends' info, close everything.
-}
pair : Task String Socket.Listener -> (Socket.Listener -> Task String Socket.Connection) -> Task String ( String, String )
pair listen connect =
    listen
        |> Task.andThen
            (\listener ->
                H.async (H.socketErr (Socket.accept listener))
                    |> Task.andThen
                        (\accepted ->
                            connect listener
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


main : Platform.Program System.Environment () ()
main =
    H.program
        (\_ ->
            pair (H.socketErr H.listenLocal) (H.connectTo >> H.socketErr)
                |> Task.andThen
                    (\( plainClient, plainServer ) ->
                        pair (H.tlsErr (T.listenTls (T.server []))) (T.connectTls (T.trusted "localhost" []) >> H.tlsErr)
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
