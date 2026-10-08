module WebSocketTlsTest exposing (main)

{-| WebSockets over TLS (plans/eco-system-websockets.md §4 WS4): a `Socket.Tls` listener whose
connections are upgraded like plain ones, and a `wss://` client trusting the test CA. The echo
works; `wss://localhost` is looked up and dialled address by address; a client that only trusts
the system certificates fails with a certificate error.
-}

-- CHECK: wss echo: Text "secret" | Binary [1,2] | Normal "" clean True
-- CHECK: localhost: Text "via name" | Normal "" clean True
-- CHECK: untrusted: certificate-invalid True handshakeFailed False
-- EXIT: 0

import Socket
import Socket.Tls
import SocketTestHelp as H
import SocketTlsHelp as T
import System
import Task exposing (Task)
import TlsFixtures as Fx
import WebSocket
import WebSocketTestHelp as W


main : System.SimpleProgram ()
main =
    H.program run


connectTo : String -> Socket.Listener -> Socket.Tls.Verification -> Task Socket.Error (WebSocket.WebSocket WebSocket.Whole)
connectTo host listener verification =
    WebSocket.defaultConnectOptions ("wss://" ++ host ++ ":" ++ String.fromInt (H.portOf listener) ++ "/secure")
        |> (\o -> { o | verification = verification })
        |> WebSocket.connect


echoCase : String -> String -> List WebSocket.Message -> Socket.Listener -> Task String String
echoCase label host messages listener =
    H.async (W.acceptOne listener |> Task.andThen W.echo)
        |> Task.andThen
            (\serverDone ->
                connectTo host listener (Socket.Tls.TrustedCertificates Fx.caPem)
                    |> Task.mapError W.wsErr
                    |> Task.andThen
                        (\ws ->
                            W.sendAll messages ws
                                |> Task.andThen (\_ -> W.readMessages (List.length messages) ws)
                                |> Task.andThen
                                    (\got ->
                                        WebSocket.close WebSocket.Normal "" ws
                                            |> Task.mapError W.wsErr
                                            |> Task.andThen (\_ -> WebSocket.closed ws)
                                            |> Task.andThen (\info -> serverDone |> Task.map (\_ -> info))
                                            |> Task.map (\info -> label ++ ": " ++ String.join " | " (List.map W.messageString got ++ [ W.closeInfoString info ]))
                                    )
                        )
            )


{-| A parked accept gives the listener the credit to run the server's side of the TLS handshake
(which then fails and is dropped; the accept is cancelled by closeListener).
-}
untrusted : Socket.Listener -> Task String String
untrusted listener =
    H.async (H.socketErr (Socket.accept listener))
        |> Task.andThen (\_ -> connectTo "127.0.0.1" listener Socket.Tls.SystemCertificates)
        |> Task.map (\_ -> "untrusted: connected?")
        |> Task.onError
            (\e ->
                Task.succeed
                    ("untrusted: certificate-invalid "
                        ++ H.boolString (Socket.errorIsCertificateInvalid e)
                        ++ " handshakeFailed "
                        ++ H.boolString (WebSocket.errorIsHandshakeFailed e)
                    )
            )


run : a -> Task String (List String)
run _ =
    H.socketErr (T.listenTls (T.server []))
        |> Task.andThen
            (\listener ->
                echoCase "wss echo" "127.0.0.1" [ W.text "secret", W.binary [ 1, 2 ] ] listener
                    |> Task.andThen (\a -> echoCase "localhost" "localhost" [ W.text "via name" ] listener |> Task.map (\b -> [ a, b ]))
                    |> Task.andThen (\lines -> untrusted listener |> Task.map (\c -> lines ++ [ c ]))
                    |> Task.andThen (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )
