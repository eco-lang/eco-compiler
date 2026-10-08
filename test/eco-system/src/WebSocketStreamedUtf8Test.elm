module WebSocketStreamedUtf8Test exposing (main)

{-| UTF-8 in streamed text bodies (plans/eco-system-websockets.md §4 WS6, Appendix D.4): a raw
client sends a text message in two fragments that split the 4-byte character 𝄞 (U+1D11E), with a
pause between them; the server's body gives "a" first (the incomplete character waits), then
"𝄞b": chunks are always whole characters. Then a text message whose second fragment holds an
invalid byte: the body gives the valid first fragment, then fails with `ERR_WS_INVALID_DATA`, and
the connection fails with 1007 (fail fast: the message never completes).
-}

-- CHECK: split: a|𝄞b end Closed
-- CHECK: invalid: ok  end Cancelled: ERR_WS_INVALID_DATA: invalid UTF-8 in a text message
-- CHECK: server end: Cancelled: ERR_WS_INVALID_DATA: invalid UTF-8 in a text message
-- CHECK: server closed: InvalidData "invalid UTF-8 in a text message" clean False
-- CHECK: raw client got: close 1007 "invalid UTF-8 in a text message"
-- EXIT: 0

import Process
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


textOf : WebSocket.WebSocket WebSocket.Streamed -> Task String String
textOf ws =
    Stream.read (WebSocket.streamedReadable ws)
        |> Task.mapError Stream.errorToString
        |> Task.andThen
            (\m ->
                case m of
                    WebSocket.StreamedText body ->
                        W.readTextBody body |> Task.map (\( chunks, end ) -> String.join "|" chunks ++ " end " ++ end)

                    WebSocket.StreamedBinary _ ->
                        Task.fail "expected text"
            )


serve : WebSocket.WebSocket WebSocket.Streamed -> Task String (List String)
serve ws =
    textOf ws
        |> Task.andThen
            (\split ->
                textOf ws
                    |> Task.andThen
                        (\invalid ->
                            Stream.read (WebSocket.streamedReadable ws)
                                |> Task.map (\_ -> "a message")
                                |> Task.onError (\e -> Task.succeed (Stream.errorToString e))
                                |> Task.andThen
                                    (\end ->
                                        WebSocket.closed ws
                                            |> Task.map
                                                (\info ->
                                                    [ "split: " ++ split
                                                    , "invalid: " ++ invalid
                                                    , "server end: " ++ end
                                                    , "server closed: " ++ W.closeInfoString info
                                                    ]
                                                )
                                    )
                        )
            )


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                H.async (W.acceptStreamed listener |> Task.andThen serve)
                    |> Task.andThen
                        (\serverDone ->
                            W.rawHandshake listener [] (W.bytesOfList [])
                                |> Task.andThen
                                    (\( conn, _, early ) ->
                                        W.rawWrite (W.maskedFrame False 0 1 (W.bytesOfList [ 0x61, 0xF0, 0x9D ])) conn
                                            |> Task.andThen (\_ -> Process.sleep 300)
                                            |> Task.andThen
                                                (\_ ->
                                                    W.sendEach conn
                                                        [ W.maskedFrame True 0 0 (W.bytesOfList [ 0x84, 0x9E, 0x62 ])
                                                        , W.maskedFrame False 0 1 (H.bytesOf "ok ")
                                                        , W.maskedFrame True 0 0 (W.bytesOfList [ 0x78, 0xFF, 0x79 ])
                                                        ]
                                                )
                                            |> Task.andThen (\_ -> W.rawReadAll conn)
                                            |> Task.map (W.concatBytes early)
                                            |> Task.andThen
                                                (\received ->
                                                    serverDone
                                                        |> Task.map (\lines -> lines ++ [ "raw client got: " ++ W.framesString (W.parseFrames received) ])
                                                )
                                    )
                        )
                    |> Task.andThen
                        (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )
