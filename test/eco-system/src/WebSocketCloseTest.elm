module WebSocketCloseTest exposing (main)

{-| Closing (plans/eco-system-websockets.md §4 WS4, W4, W14, Appendix D.5), with raw clients: a
received Close sets `CloseInfo` (any valid code, `NoStatus` for an empty payload) and is echoed
once with its code; a 1-byte payload or an invalid code fails with 1002; data after a Close is
ignored; a peer that drops the connection without a Close is `Abnormal`. Our `close` refuses the
codes that cannot be sent (`EINVAL`), cuts the reason to 123 bytes on a character boundary, may be
called twice, and `closed` reports the peer's answer.
-}

-- CHECK: code 4000: server Closed | Other 4000 "app" clean True | raw close 4000 ""
-- CHECK: empty payload: server Closed | NoStatus "" clean True | raw close
-- CHECK: one byte: server Cancelled: ERR_WS_PROTOCOL: a Close frame with a 1-byte payload | ProtocolError "a Close frame with a 1-byte payload" clean False | raw close 1002
-- CHECK: code 1004: server Cancelled: ERR_WS_PROTOCOL: invalid close code 1004 | ProtocolError "invalid close code 1004" clean False | raw close 1002
-- CHECK: code 999: server Cancelled: ERR_WS_PROTOCOL: invalid close code 999 | ProtocolError
-- CHECK: data after close: server Closed | Normal "bye" clean True | raw close 1000 ""
-- CHECK: dropped: server Cancelled: socket closed | Abnormal "" clean False | raw
-- CHECK: unsendable: NoStatus EINVAL, Abnormal EINVAL, Other 999 EINVAL, Other 5000 EINVAL, Other 1004 EINVAL
-- CHECK: server close: close twice ok ok | GoingAway "" clean True | raw close 1001 reason bytes 122 chars 61
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


cases : List ( String, Bytes )
cases =
    [ ( "code 4000", W.maskedFrame True 0 8 (W.closePayload 4000 "app") )
    , ( "empty payload", W.maskedFrame True 0 8 (W.bytesOfList []) )
    , ( "one byte", W.maskedFrame True 0 8 (W.bytesOfList [ 3 ]) )
    , ( "code 1004", W.maskedFrame True 0 8 (W.closePayload 1004 "") )
    , ( "code 999", W.maskedFrame True 0 8 (W.closePayload 999 "") )
    , ( "data after close", W.concatBytes (W.maskedFrame True 0 8 (W.closePayload 1000 "bye")) (W.maskedFrame True 0 1 (H.bytesOf "late")) )
    ]


serverCase : Socket.Listener -> ( String, Bytes ) -> Task String String
serverCase listener ( label, bytes ) =
    H.async
        (W.acceptOne listener
            |> Task.andThen (\ws -> W.readAll ws |> Task.andThen (\( _, end ) -> WebSocket.closed ws |> Task.map (\info -> ( end, info ))))
        )
        |> Task.andThen
            (\serverDone ->
                W.rawHandshake listener [] bytes
                    |> Task.andThen (\( conn, _, early ) -> W.rawReadAll conn |> Task.map (W.concatBytes early))
                    |> Task.andThen
                        (\received ->
                            serverDone
                                |> Task.map
                                    (\( end, info ) ->
                                        label ++ ": server " ++ end ++ " | " ++ W.closeInfoString info ++ " | raw " ++ W.framesString (W.parseFrames received)
                                    )
                        )
            )


{-| The raw client closes the TCP connection without a Close frame.
-}
droppedCase : Socket.Listener -> Task String String
droppedCase listener =
    H.async
        (W.acceptOne listener
            |> Task.andThen (\ws -> W.readAll ws |> Task.andThen (\( _, end ) -> WebSocket.closed ws |> Task.map (\info -> ( end, info ))))
        )
        |> Task.andThen
            (\serverDone ->
                W.rawHandshake listener [] (W.bytesOfList [])
                    |> Task.andThen (\( conn, _, _ ) -> H.socketErr (Socket.close conn))
                    |> Task.andThen (\_ -> serverDone)
                    |> Task.map (\( end, info ) -> "dropped: server " ++ end ++ " | " ++ W.closeInfoString info ++ " | raw")
            )


{-| Our server closes (twice) with GoingAway and a reason of 200 bytes; the raw client answers.
-}
serverCloseCase : Socket.Listener -> Task String (List String)
serverCloseCase listener =
    H.async (W.acceptOne listener)
        |> Task.andThen
            (\accepted ->
                W.rawHandshake listener [] (W.bytesOfList [])
                    |> Task.andThen
                        (\( conn, _, _ ) ->
                            accepted
                                |> Task.andThen
                                    (\ws ->
                                        let
                                            try code =
                                                WebSocket.close code "x" ws
                                                    |> Task.map (\_ -> W.codeString code ++ " ok")
                                                    |> Task.onError (\e -> Task.succeed (W.codeString code ++ " " ++ Socket.errorCode e))
                                        in
                                        [ WebSocket.NoStatus, WebSocket.Abnormal, WebSocket.Other 999, WebSocket.Other 5000, WebSocket.Other 1004 ]
                                            |> List.map try
                                            |> Task.sequence
                                            |> Task.andThen
                                                (\refused ->
                                                    W.describe (WebSocket.close WebSocket.GoingAway (String.repeat 100 "é") ws)
                                                        |> Task.andThen (\a -> W.describe (WebSocket.close WebSocket.GoingAway "again" ws) |> Task.map (\b -> ( a, b )))
                                                        |> Task.andThen
                                                            (\( a, b ) ->
                                                                W.rawRead conn
                                                                    |> Task.andThen
                                                                        (\chunk ->
                                                                            W.rawWrite (W.maskedFrame True 0 8 (W.closePayload 1001 "")) conn
                                                                                |> Task.andThen (\_ -> W.rawReadAll conn)
                                                                                |> Task.andThen (\_ -> WebSocket.closed ws)
                                                                                |> Task.map
                                                                                    (\info ->
                                                                                        [ "unsendable: " ++ String.join ", " refused
                                                                                        , "server close: close twice "
                                                                                            ++ a
                                                                                            ++ " "
                                                                                            ++ b
                                                                                            ++ " | "
                                                                                            ++ W.closeInfoString info
                                                                                            ++ " | raw "
                                                                                            ++ closeSummary chunk
                                                                                        ]
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


closeSummary : Bytes -> String
closeSummary chunk =
    case W.parseFrames chunk of
        ( 8, hi :: lo :: reason ) :: _ ->
            let
                text =
                    W.latin1 (W.bytesOfList reason)
            in
            "close "
                ++ String.fromInt (hi * 256 + lo)
                ++ " reason bytes "
                ++ String.fromInt (List.length reason)
                ++ " chars "
                ++ String.fromInt (String.length (String.replace "Ã©" "é" text))

        _ ->
            "?"


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                (List.map (serverCase listener) cases ++ [ droppedCase listener ])
                    |> sequence
                    |> Task.andThen (\lines -> serverCloseCase listener |> Task.map (\more -> lines ++ more))
                    |> Task.andThen (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )


sequence : List (Task String String) -> Task String (List String)
sequence tasks =
    case tasks of
        [] ->
            Task.succeed []

        t :: rest ->
            t |> Task.andThen (\x -> sequence rest |> Task.map ((::) x))
