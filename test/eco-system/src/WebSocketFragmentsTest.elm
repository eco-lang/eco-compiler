module WebSocketFragmentsTest exposing (main)

{-| Fragmented messages (plans/eco-system-websockets.md §4 WS4, Appendix D.1, D.4): a raw client
sends a text message in three fragments with a ping between the first two, a binary message in
two fragments, a frame whose header arrives in two writes, then a Close. The server reads one
`Text` and one `Binary` value (fragment boundaries are never exposed), the raw client gets the
pong (with the ping's payload, ahead of everything else) and the server's Close echo.
-}

-- CHECK: status: HTTP/1.1 101 Switching Protocols
-- CHECK: server got: Text "Hello world" | Binary [1,2,3] | Text "split"
-- CHECK: server end: Closed
-- CHECK: server closed: Normal "bye" clean True
-- CHECK: raw client got: pong [7,7] | close 1000 ""
-- EXIT: 0

import Bytes exposing (Bytes)
import Socket
import SocketTestHelp as H
import System
import Task exposing (Task)
import WebSocket
import WebSocketTestHelp as W


main : System.SimpleProgram ()
main =
    H.program run


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                H.async
                    (W.acceptOne listener
                        |> Task.andThen
                            (\ws ->
                                W.readMessages 3 ws
                                    |> Task.andThen
                                        (\got ->
                                            W.readAll ws
                                                |> Task.andThen
                                                    (\( _, end ) ->
                                                        WebSocket.closed ws
                                                            |> Task.map
                                                                (\info ->
                                                                    [ "server got: " ++ String.join " | " (List.map W.messageString got)
                                                                    , "server end: " ++ end
                                                                    , "server closed: " ++ W.closeInfoString info
                                                                    ]
                                                                )
                                                    )
                                        )
                            )
                    )
                    |> Task.andThen
                        (\serverDone ->
                            W.rawHandshake listener [] (W.bytesOfList [])
                                |> Task.andThen
                                    (\( conn, status, early ) ->
                                        sendEach conn
                                            [ W.maskedFrame False 0 1 (H.bytesOf "Hel")
                                            , W.maskedFrame True 0 9 (W.bytesOfList [ 7, 7 ])
                                            , W.maskedFrame False 0 0 (H.bytesOf "lo")
                                            , W.maskedFrame True 0 0 (H.bytesOf " world")
                                            , W.maskedFrame False 0 2 (W.bytesOfList [ 1, 2 ])
                                            , W.maskedFrame True 0 0 (W.bytesOfList [ 3 ])
                                            , W.bytesOfList [ 0x81 ]
                                            , W.bytesOfList (List.drop 1 (W.listOfBytes (W.maskedFrame True 0 1 (H.bytesOf "split"))))
                                            , W.maskedFrame True 0 8 (W.closePayload 1000 "bye")
                                            ]
                                            |> Task.andThen (\_ -> W.rawReadAll conn)
                                            |> Task.map (W.concatBytes early)
                                            |> Task.andThen
                                                (\received ->
                                                    serverDone
                                                        |> Task.map
                                                            (\lines ->
                                                                ("status: " ++ status)
                                                                    :: lines
                                                                    ++ [ "raw client got: " ++ W.framesString (W.parseFrames received) ]
                                                            )
                                                )
                                    )
                        )
                    |> Task.andThen
                        (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )


sendEach : Socket.Connection -> List Bytes -> Task String ()
sendEach conn frames =
    case frames of
        [] ->
            Task.succeed ()

        f :: rest ->
            W.rawWrite f conn |> Task.andThen (\_ -> sendEach conn rest)
