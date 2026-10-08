module WebSocketDeflateStreamedTest exposing (main)

{-| Streamed messages with permessage-deflate (plans/eco-system-websockets.md §4 WS7, §3.7), with
context takeover on both sides, between our client and our server:

  - the client streams 20 MiB; every chunk is compressed as it is sent, the server's body gives
    it back inflated and in order;
  - the server streams a text message; the client gets whole characters;
  - skipping: the server streams an 8 MiB message A, then sends B, a short binary message whose
    bytes also occur at the end of A (with context takeover it is compressed as back-references
    into A). The client reads one chunk of A and cancels it; A is still inflated (the shared
    window stays in sync), so B arrives intact.

-}

-- CHECK: compression: client (False,False,15,15) server (False,False,15,15)
-- CHECK: client to server: 20971520 bytes, pattern True
-- CHECK: text: héllo wörld ✓
-- CHECK: skipped A, then B: 1024 bytes, pattern True
-- CHECK: after: Text "bye"
-- CHECK: client closed: Normal "" clean True
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Socket
import SocketTestHelp as H
import Stream
import System
import Task exposing (Task)
import WebSocket
import WebSocketTestHelp as W


main : System.SimpleProgram ()
main =
    H.program run


describeCompression : Maybe WebSocket.Negotiated -> String
describeCompression c =
    case c of
        Just n ->
            "("
                ++ String.join ","
                    [ H.boolString n.serverNoContextTakeover
                    , H.boolString n.clientNoContextTakeover
                    , String.fromInt n.serverMaxWindowBits
                    , String.fromInt n.clientMaxWindowBits
                    ]
                ++ ")"

        Nothing ->
            "none"


{-| 1024 bytes counting 0..255: the end of every pattern chunk.
-}
b : Bytes
b =
    E.encode (E.sequence (List.repeat 4 (E.sequence (List.map E.unsignedInt8 (List.range 0 255)))))


next : WebSocket.WebSocket WebSocket.Streamed -> Task String WebSocket.StreamedMessage
next ws =
    Stream.read (WebSocket.streamedReadable ws) |> Task.mapError Stream.errorToString


server : WebSocket.WebSocket WebSocket.Streamed -> Task String String
server ws =
    next ws
        |> Task.andThen
            (\m ->
                case m of
                    WebSocket.StreamedBinary body ->
                        W.readPatternBody body

                    WebSocket.StreamedText _ ->
                        Task.fail "expected binary"
            )
        |> Task.andThen
            (\( size, ok ) ->
                Stream.fromList [ "héllo ", "wörld", " ✓" ]
                    |> Task.mapError Stream.errorToString
                    |> Task.andThen (\source -> WebSocket.sendText source ws |> Task.mapError W.wsErr)
                    |> Task.andThen (\_ -> W.patternSource 128 65536)
                    |> Task.andThen (\source -> WebSocket.sendBinary source ws |> Task.mapError W.wsErr)
                    |> Task.andThen (\_ -> Stream.write (WebSocket.Binary b) (WebSocket.writable ws) |> Task.mapError Stream.errorToString)
                    |> Task.andThen (\_ -> next ws)
                    |> Task.andThen
                        (\after ->
                            case after of
                                WebSocket.StreamedText body ->
                                    W.readTextBody body |> Task.map (\( chunks, _ ) -> String.concat chunks)

                                WebSocket.StreamedBinary _ ->
                                    Task.succeed "binary?"
                        )
                    |> Task.andThen
                        (\afterText ->
                            next ws
                                |> Task.map (\_ -> "a message")
                                |> Task.onError (\_ -> Task.succeed "")
                                |> Task.map
                                    (\_ ->
                                        "client to server: "
                                            ++ String.fromInt size
                                            ++ " bytes, pattern "
                                            ++ H.boolString ok
                                            ++ "\nafter: Text \""
                                            ++ afterText
                                            ++ "\""
                                    )
                        )
            )


run : a -> Task String (List String)
run _ =
    let
        d =
            WebSocket.defaultAcceptOptions

        takeover o =
            { o | compression = Maybe.map (\c -> { c | contextTakeover = True, threshold = 0 }) o.compression }
    in
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                H.async (W.acceptStreamedWith (takeover d) listener |> Task.andThen (\ws -> server ws |> Task.map (\r -> ( ws, r ))))
                    |> Task.andThen
                        (\serverDone ->
                            W.connectStreamed takeover listener
                                |> Task.andThen
                                    (\client ->
                                        W.patternSource 320 65536
                                            |> Task.andThen (\source -> WebSocket.sendBinary source client |> Task.mapError W.wsErr)
                                            |> Task.andThen (\_ -> next client)
                                            |> Task.andThen
                                                (\m ->
                                                    case m of
                                                        WebSocket.StreamedText body ->
                                                            W.readTextBody body |> Task.map (\( chunks, _ ) -> String.concat chunks)

                                                        WebSocket.StreamedBinary _ ->
                                                            Task.fail "expected text"
                                                )
                                            |> Task.andThen
                                                (\text ->
                                                    next client
                                                        |> Task.andThen
                                                            (\a ->
                                                                case a of
                                                                    WebSocket.StreamedBinary body ->
                                                                        Stream.read body
                                                                            |> Task.mapError Stream.errorToString
                                                                            |> Task.andThen (\_ -> Stream.cancelReadable "skip" body |> Task.mapError Stream.errorToString)

                                                                    WebSocket.StreamedText _ ->
                                                                        Task.fail "expected binary"
                                                            )
                                                        |> Task.andThen (\_ -> next client)
                                                        |> Task.andThen
                                                            (\bm ->
                                                                case bm of
                                                                    WebSocket.StreamedBinary body ->
                                                                        W.readPatternBody body

                                                                    WebSocket.StreamedText _ ->
                                                                        Task.fail "expected binary"
                                                            )
                                                        |> Task.andThen
                                                            (\( bSize, bOk ) ->
                                                                Stream.write (WebSocket.Text "bye") (WebSocket.writable client)
                                                                    |> Task.mapError Stream.errorToString
                                                                    |> Task.andThen (\_ -> WebSocket.close WebSocket.Normal "" client |> Task.mapError W.wsErr)
                                                                    |> Task.andThen (\_ -> serverDone)
                                                                    |> Task.andThen
                                                                        (\( s, serverLines ) ->
                                                                            WebSocket.closed client
                                                                                |> Task.map
                                                                                    (\ci ->
                                                                                        [ "compression: client "
                                                                                            ++ describeCompression (WebSocket.compression client)
                                                                                            ++ " server "
                                                                                            ++ describeCompression (WebSocket.compression s)
                                                                                        , serverLines
                                                                                        , "text: " ++ text
                                                                                        , "skipped A, then B: " ++ String.fromInt bSize ++ " bytes, pattern " ++ H.boolString bOk
                                                                                        , "client closed: " ++ W.closeInfoString ci
                                                                                        ]
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
                    |> Task.andThen
                        (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )
