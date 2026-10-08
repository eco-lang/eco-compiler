module WebSocketHttp2StreamedTest exposing (main)

{-| Streamed messages and permessage-deflate over an HTTP/2 stream together (plans/eco-system-
websockets.md W7, W8, W12; integration of WS6/WS7 with WS9): a client connects with
`connectStreamed` and `http2 = True` (compression on, the default) to an `Http.Server` with HTTP/2;
the server accepts with `WebSocket.accept` (Whole mode) and echoes. The client sends a 4 MiB binary
message with `sendBinary` from a generated stream and a streamed text message, and reads both
echoes as streamed bodies. HTTP/2 flow control, the codec's streamed lanes and the deflate engine
all run on the one tunnel.
-}

-- CHECK: server: upgrade /streamed Http2
-- CHECK: server: ws /streamed: Closed | Normal "" clean True
-- CHECK: client: compression: True
-- CHECK: client: big echoed: 4194304 bytes, pattern True
-- CHECK: client: text echoed: héllo wörld ✓
-- CHECK: client: closed: Normal "" clean True
-- CHECK-NOT: failed
-- EXIT: 0

import Http.Server as Server
import Socket.Tls
import Stream
import Task exposing (Task)
import TlsFixtures as Fx
import WebSocket
import WebSocketH2Help as H
import WebSocketTestHelp as W


connectStreamed : Int -> Task String (WebSocket.WebSocket WebSocket.Streamed)
connectStreamed port_ =
    let
        d =
            WebSocket.defaultConnectOptions ("wss://localhost:" ++ String.fromInt port_ ++ "/streamed")
    in
    WebSocket.connectStreamed
        { d
            | verification = Socket.Tls.TrustedCertificates Fx.caPem
            , http2 = True
            , timeout = Just 10000
        }
        |> Task.mapError W.wsErr


nextBody : WebSocket.WebSocket WebSocket.Streamed -> Task String WebSocket.StreamedMessage
nextBody ws =
    Stream.read (WebSocket.streamedReadable ws) |> Task.mapError Stream.errorToString


run : WebSocket.WebSocket WebSocket.Streamed -> Task String (List String)
run ws =
    W.patternSource 64 65536
        |> Task.andThen (\source -> WebSocket.sendBinary source ws |> Task.mapError W.wsErr)
        |> Task.andThen (\_ -> nextBody ws)
        |> Task.andThen
            (\m ->
                case m of
                    WebSocket.StreamedBinary body ->
                        W.readPatternBody body

                    WebSocket.StreamedText _ ->
                        Task.fail "expected a binary message"
            )
        |> Task.andThen
            (\( size, ok ) ->
                Stream.fromList [ "héllo ", "wörld", " ✓" ]
                    |> Task.mapError Stream.errorToString
                    |> Task.andThen (\source -> WebSocket.sendText source ws |> Task.mapError W.wsErr)
                    |> Task.andThen (\_ -> nextBody ws)
                    |> Task.andThen
                        (\m ->
                            case m of
                                WebSocket.StreamedText body ->
                                    W.readTextBody body |> Task.map (\( chunks, _ ) -> String.concat chunks)

                                WebSocket.StreamedBinary _ ->
                                    Task.fail "expected a text message"
                        )
                    |> Task.andThen
                        (\text ->
                            WebSocket.close WebSocket.Normal "" ws
                                |> Task.mapError W.wsErr
                                |> Task.andThen (\_ -> WebSocket.closed ws)
                                |> Task.map
                                    (\info ->
                                        [ "compression: " ++ (if WebSocket.compression ws /= Nothing then "True" else "False")
                                        , "big echoed: " ++ String.fromInt size ++ " bytes, pattern " ++ (if ok then "True" else "False")
                                        , "text echoed: " ++ text
                                        , "closed: " ++ W.closeInfoString info
                                        ]
                                    )
                        )
            )


client : H.Tools -> List Server.Server -> Task String (List String)
client _ servers =
    case servers of
        [ h2 ] ->
            connectStreamed (Server.serverPort h2)
                |> Task.andThen run
                |> Task.onError (\e -> Task.succeed [ "failed " ++ e ])

        _ ->
            Task.fail "one server expected"


main =
    H.program { servers = [ identity ], client = client }
