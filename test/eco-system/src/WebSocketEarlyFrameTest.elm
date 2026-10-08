module WebSocketEarlyFrameTest exposing (main)

{-| Frames that arrive in the same read as the handshake (plans/eco-system-websockets.md §4 WS4,
§3.6): a raw server writes its 101, two text frames and a Close in one write, and the client
reads both messages and then `Closed`; a raw client writes its opening request and a first frame
(and a Close) in one write, and the server reads the message and then `Closed`.
-}

-- CHECK: client got: Text "early" | Text "second" end Closed
-- CHECK: client closed: Normal "server done" clean True
-- CHECK: server got: Text "early from client" end Closed
-- EXIT: 0

import Socket
import SocketTestHelp as H
import System
import Task exposing (Task)
import WebSocket
import WebSocketSha1 exposing (acceptFor)
import WebSocketTestHelp as W


main : System.SimpleProgram ()
main =
    H.program run


switching : String -> String
switching key =
    String.join "\u{000D}\n"
        [ "HTTP/1.1 101 Switching Protocols"
        , "Upgrade: websocket"
        , "Connection: Upgrade"
        , "Sec-WebSocket-Accept: " ++ acceptFor key
        ]
        ++ "\u{000D}\n\u{000D}\n"


clientSide : Socket.Listener -> Task String (List String)
clientSide listener =
    H.async
        (W.rawUpgradeClient listener
            (\key ->
                List.foldl (\b acc -> W.concatBytes acc b)
                    (H.bytesOf (switching key))
                    [ W.frame True 0 1 (H.bytesOf "early")
                    , W.frame True 0 1 (H.bytesOf "second")
                    , W.frame True 0 8 (W.closePayload 1000 "server done")
                    ]
            )
            |> Task.andThen (\( conn, _ ) -> W.rawRead conn |> Task.andThen (\_ -> H.socketErr (Socket.close conn)))
        )
        |> Task.andThen
            (\serverDone ->
                W.connect listener
                    |> Task.andThen
                        (\ws ->
                            W.readAll ws
                                |> Task.andThen
                                    (\( got, end ) ->
                                        serverDone
                                            |> Task.andThen (\_ -> WebSocket.closed ws)
                                            |> Task.map
                                                (\info ->
                                                    [ "client got: " ++ String.join " | " (List.map W.messageString got) ++ " end " ++ end
                                                    , "client closed: " ++ W.closeInfoString info
                                                    ]
                                                )
                                    )
                        )
            )


serverSide : Socket.Listener -> Task String (List String)
serverSide listener =
    H.async (W.acceptOne listener |> Task.andThen W.readAll)
        |> Task.andThen
            (\serverDone ->
                W.rawHandshake listener
                    []
                    (W.concatBytes (W.maskedFrame True 0 1 (H.bytesOf "early from client")) (W.maskedFrame True 0 8 (W.closePayload 1000 "")))
                    |> Task.andThen (\( conn, _, _ ) -> W.rawReadAll conn)
                    |> Task.andThen (\_ -> serverDone)
                    |> Task.map (\( got, end ) -> [ "server got: " ++ String.join " | " (List.map W.messageString got) ++ " end " ++ end ])
            )


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                clientSide listener
                    |> Task.andThen (\a -> serverSide listener |> Task.map (\b -> a ++ b))
                    |> Task.andThen (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )
