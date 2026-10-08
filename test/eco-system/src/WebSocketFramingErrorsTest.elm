module WebSocketFramingErrorsTest exposing (main)

{-| Framing errors fail the connection with 1002 (1009 for a message over `maxMessageSize`)
(plans/eco-system-websockets.md §4 WS4, Appendix D.1, D.5, D.9). Raw clients send one bad frame
after a valid handshake; the server's readable fails with the D.9 reason, `closed` reports our
code and text (clean False), and the raw client receives our Close. A client receiving a masked
frame from a raw server fails the same way.
-}

-- CHECK: unmasked: server Cancelled: ERR_WS_PROTOCOL: an unmasked client frame | ProtocolError "an unmasked client frame" clean False | raw close 1002 "an unmasked client frame"
-- CHECK: rsv1: server Cancelled: ERR_WS_PROTOCOL: RSV1 is set without a negotiated extension | ProtocolError "RSV1 is set without a negotiated extension" clean False | raw close 1002 "RSV1 is set without a negotiated extension"
-- CHECK: rsv2: server Cancelled: ERR_WS_PROTOCOL: RSV2 or RSV3 is set | ProtocolError "RSV2 or RSV3 is set" clean False | raw close 1002 "RSV2 or RSV3 is set"
-- CHECK: reserved opcode: server Cancelled: ERR_WS_PROTOCOL: a reserved opcode | ProtocolError "a reserved opcode" clean False | raw close 1002 "a reserved opcode"
-- CHECK: long control: server Cancelled: ERR_WS_PROTOCOL: a control frame longer than 125 bytes | ProtocolError "a control frame longer than 125 bytes" clean False | raw close 1002
-- CHECK: fragmented control: server Cancelled: ERR_WS_PROTOCOL: a fragmented control frame | ProtocolError "a fragmented control frame" clean False | raw close 1002
-- CHECK: 64-bit msb: server Cancelled: ERR_WS_PROTOCOL: a 64-bit length with the most significant bit set | ProtocolError "a 64-bit length with the most significant bit set" clean False | raw close 1002
-- CHECK: lone continuation: server Cancelled: ERR_WS_PROTOCOL: a continuation frame without a message in progress | ProtocolError
-- CHECK: data inside message: server Cancelled: ERR_WS_PROTOCOL: a new data frame inside a fragmented message | ProtocolError
-- CHECK: too big: server Cancelled: ERR_WS_MESSAGE_TOO_BIG | MessageTooBig "the message is larger than maxMessageSize" clean False | raw close 1009
-- CHECK: masked server frame: client Cancelled: ERR_WS_PROTOCOL: a masked server frame | ProtocolError "a masked server frame" clean False | raw close 1002 "a masked server frame"
-- EXIT: 0

import Bytes exposing (Bytes)
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


cases : List ( String, Bytes, Int )
cases =
    [ ( "unmasked", W.frame True 0 1 (H.bytesOf "x"), 16777216 )
    , ( "rsv1", W.maskedFrame True 4 1 (H.bytesOf "x"), 16777216 )
    , ( "rsv2", W.maskedFrame True 2 1 (H.bytesOf "x"), 16777216 )
    , ( "reserved opcode", W.maskedFrame True 0 3 (H.bytesOf "x"), 16777216 )
    , ( "long control", W.maskedFrame True 0 9 (H.bytesOf (String.repeat 126 "p")), 16777216 )
    , ( "fragmented control", W.maskedFrame False 0 9 (H.bytesOf "p"), 16777216 )
    , ( "64-bit msb", W.bytesOfList [ 0x82, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 4 ], 16777216 )
    , ( "lone continuation", W.maskedFrame True 0 0 (H.bytesOf "x"), 16777216 )
    , ( "data inside message", W.concatBytes (W.maskedFrame False 0 1 (H.bytesOf "a")) (W.maskedFrame True 0 1 (H.bytesOf "b")), 16777216 )
    , ( "too big", W.maskedFrame True 0 2 (W.bytesOfList (List.repeat 11 0)), 10 )
    ]


serverCase : Socket.Listener -> ( String, Bytes, Int ) -> Task String String
serverCase listener ( label, bad, maxSize ) =
    let
        options =
            WebSocket.defaultAcceptOptions
    in
    H.async
        (W.acceptWith { options | maxMessageSize = maxSize } listener
            |> Task.andThen (\ws -> W.readAll ws |> Task.andThen (\( _, end ) -> WebSocket.closed ws |> Task.map (\info -> ( end, info ))))
        )
        |> Task.andThen
            (\serverDone ->
                W.rawHandshake listener [] bad
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


clientCase : Socket.Listener -> Task String String
clientCase listener =
    H.async
        (W.rawUpgradeClient listener
            (\key ->
                W.concatBytes
                    (H.bytesOf
                        (String.join "\u{000D}\n"
                            [ "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Accept: " ++ acceptFor key ]
                            ++ "\u{000D}\n\u{000D}\n"
                        )
                    )
                    (W.maskedFrame True 0 1 (H.bytesOf "masked"))
            )
            |> Task.andThen (\( conn, _ ) -> W.rawReadAll conn |> Task.andThen (\r -> H.socketErr (Socket.close conn) |> Task.map (\_ -> r)))
        )
        |> Task.andThen
            (\serverDone ->
                W.connect listener
                    |> Task.andThen
                        (\ws ->
                            W.readAll ws
                                |> Task.andThen
                                    (\( _, end ) ->
                                        WebSocket.closed ws
                                            |> Task.andThen
                                                (\info ->
                                                    serverDone
                                                        |> Task.map
                                                            (\received ->
                                                                "masked server frame: client " ++ end ++ " | " ++ W.closeInfoString info ++ " | raw " ++ W.framesString (W.parseFrames received)
                                                            )
                                                )
                                    )
                        )
            )


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                (List.map (serverCase listener) cases ++ [ clientCase listener ])
                    |> sequence
                    |> Task.andThen (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )


sequence : List (Task String String) -> Task String (List String)
sequence tasks =
    case tasks of
        [] ->
            Task.succeed []

        t :: rest ->
            t |> Task.andThen (\x -> sequence rest |> Task.map ((::) x))
