module WebSocketEchoTest exposing (main)

{-| WebSocket echo over loopback (plans/eco-system-websockets.md §4 WS4): a `Socket.Tcp` listener
whose connection is upgraded with `WebSocket.upgradeRequest` and accepted; the server echoes every
message until its readable ends. The client sends text and binary messages interleaved (empty
ones, non-ASCII text, a 70 000-byte message with a 64-bit length and a 300 000-byte one sent in
fragments) and reads the echoes back in order (compressed: permessage-deflate is on by default,
WS7), then closes with `Normal "done"`; both readables end
`Closed` and both sides report a clean close: the server sees the client's Close, the client the
server's echo (its code, no reason: D.5).
-}

-- CHECK: client got: Text "hello" | Binary [1,2,3] | Text "ünïcödé ✓ 𝄞" | Binary [] | Text "" | Binary 70000 bytes | Text "bye"
-- CHECK: big echoed intact: True
-- CHECK: client end: Closed
-- CHECK: server end: Closed
-- CHECK: client closed: Normal "" clean True
-- CHECK: server closed: Normal "done" clean True
-- CHECK: protocol Nothing compression True
-- CHECK: endpoints agree: True
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Socket
import Socket.Address exposing (Endpoint(..))
import SocketTestHelp as H
import System
import Task exposing (Task)
import WebSocket
import WebSocketTestHelp as W


main : System.SimpleProgram ()
main =
    H.program run


big : Bytes
big =
    E.encode (E.sequence (List.repeat 75000 (E.unsignedInt32 Bytes.BE 0x01020304)))


messages : List WebSocket.Message
messages =
    [ W.text "hello"
    , W.binary [ 1, 2, 3 ]
    , W.text "ünïcödé ✓ 𝄞"
    , W.binary []
    , W.text ""
    , WebSocket.Binary (E.encode (E.sequence (List.repeat 70000 (E.unsignedInt8 7))))
    , W.text "bye"
    ]


portOfEndpoint : Endpoint -> Int
portOfEndpoint ep =
    case ep of
        Inet i ->
            i.port_

        Unix _ ->
            -1


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                H.async (W.acceptOne listener |> Task.andThen (\ws -> W.echo ws |> Task.map (\end -> ( ws, end ))))
                    |> Task.andThen
                        (\serverDone ->
                            W.connect listener
                                |> Task.andThen
                                    (\client ->
                                        W.sendAll (messages ++ [ WebSocket.Binary big ]) client
                                            |> Task.andThen (\_ -> W.readMessages (List.length messages + 1) client)
                                            |> Task.andThen
                                                (\got ->
                                                    WebSocket.close WebSocket.Normal "done" client
                                                        |> Task.mapError W.wsErr
                                                        |> Task.andThen (\_ -> W.readAll client)
                                                        |> Task.andThen
                                                            (\( _, clientEnd ) ->
                                                                serverDone
                                                                    |> Task.andThen
                                                                        (\( server, serverEnd ) ->
                                                                            Task.map2
                                                                                (\ci si ->
                                                                                    [ "client got: " ++ String.join " | " (List.map W.messageString (List.take (List.length messages) got))
                                                                                    , "big echoed intact: " ++ H.boolString (List.drop (List.length messages) got == [ WebSocket.Binary big ])
                                                                                    , "client end: " ++ clientEnd
                                                                                    , "server end: " ++ serverEnd
                                                                                    , "client closed: " ++ W.closeInfoString ci
                                                                                    , "server closed: " ++ W.closeInfoString si
                                                                                    , "protocol "
                                                                                        ++ Maybe.withDefault "Nothing" (WebSocket.protocol client)
                                                                                        ++ " compression "
                                                                                        ++ H.boolString (WebSocket.compression client /= Nothing)
                                                                                    , "endpoints agree: "
                                                                                        ++ H.boolString
                                                                                            (portOfEndpoint (WebSocket.localEndpoint client)
                                                                                                == portOfEndpoint (WebSocket.remoteEndpoint server)
                                                                                                && portOfEndpoint (WebSocket.remoteEndpoint client)
                                                                                                == H.portOf listener
                                                                                            )
                                                                                    ]
                                                                                )
                                                                                (WebSocket.closed client)
                                                                                (WebSocket.closed server)
                                                                        )
                                                            )
                                                )
                                    )
                        )
                    |> Task.andThen
                        (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )
