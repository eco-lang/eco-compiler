module SocketTlsTimeoutTest exposing (main)

{-| The connect timeout covers the TLS handshake too (plans/eco-system-sockets.md §3.3.3 "Connect",
Appendix A `Socket.Tcp.ConnectOptions.timeout`): a TLS client connecting to a plain TCP server that
accepts but never answers fails with `ETIMEDOUT` once the timeout passes.
-}

-- CHECK: handshake timeout: err ETIMEDOUT
-- CHECK: closed: ok
-- EXIT: 0

import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import Socket.Tls
import SocketTestHelp as H
import SocketTlsHelp as T
import System
import Task


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr H.listenLocal
                |> Task.andThen
                    (\listener ->
                        H.async (H.socketErr (Socket.accept listener))
                            |> Task.andThen
                                (\accepted ->
                                    let
                                        tcp =
                                            Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) (H.portOf listener)
                                    in
                                    H.describe (Socket.Tls.connect (T.trusted "localhost" []) { tcp | timeout = Just 300 })
                                        |> Task.andThen
                                            (\timedOut ->
                                                accepted
                                                    |> Task.andThen Socket.close
                                                    |> Task.andThen (\_ -> H.describe (Socket.closeListener listener))
                                                    |> Task.map (\closed -> [ "handshake timeout: " ++ timedOut, "closed: " ++ closed ])
                                            )
                                )
                    )
        )
