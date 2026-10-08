module WebSocketStreamedTest exposing (main)

{-| Streamed messages both ways (plans/eco-system-websockets.md §4 WS6, W7): a client connects in
the streamed mode and sends a 100 MiB binary message with `sendBinary` from a stream that is
generated as it is read; the server (`acceptStreamed`) pipes the body it receives straight back
with `sendBinary`, and the client reads the echo's body to its end while it is still sending. Then
a streamed text message (answered with a whole `Text` by the server) and an empty streamed message.
No compression (WebSocketDeflateStreamedTest covers compressed bodies).

The memory bound of streaming is checked by WebSocketStreamedMemoryTest: here every received chunk
becomes an Elm `Bytes` value, and the native runtime does not reclaim large `Bytes` without a major
GC, which this program never triggers (plans/eco-system-websockets.md §10 WS6), so the process's
size says nothing about the WebSocket layer.
-}

-- CHECK: big echoed: 104857600 bytes, pattern True
-- CHECK: text echoed: Text "héllo wörld ✓"
-- CHECK: empty echoed: 0 bytes, pattern True
-- CHECK: client end: Closed
-- CHECK: server end: Closed
-- CHECK: client closed: Normal "" clean True
-- CHECK: server closed: Normal "done" clean True
-- EXIT: 0

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


{-| Echo every streamed message until the readable ends: binary bodies are piped back as they
arrive, text bodies are read whole and answered with one `Text`.
-}
serve : WebSocket.WebSocket WebSocket.Streamed -> Task String String
serve ws =
    Stream.read (WebSocket.streamedReadable ws)
        |> Task.map Ok
        |> Task.onError (\e -> Task.succeed (Err e))
        |> Task.andThen
            (\r ->
                case r of
                    Ok (WebSocket.StreamedBinary body) ->
                        WebSocket.sendBinary body ws
                            |> Task.mapError W.wsErr
                            |> Task.andThen (\_ -> serve ws)

                    Ok (WebSocket.StreamedText body) ->
                        W.readTextBody body
                            |> Task.andThen
                                (\( chunks, _ ) ->
                                    Stream.write (WebSocket.Text (String.concat chunks)) (WebSocket.writable ws)
                                        |> Task.mapError Stream.errorToString
                                )
                            |> Task.andThen (\_ -> serve ws)

                    Err e ->
                        Task.succeed (Stream.errorToString e)
            )


nextBody : WebSocket.WebSocket WebSocket.Streamed -> Task String WebSocket.StreamedMessage
nextBody ws =
    Stream.read (WebSocket.streamedReadable ws) |> Task.mapError Stream.errorToString


binaryBody : WebSocket.StreamedMessage -> Task String ( Int, Bool )
binaryBody m =
    case m of
        WebSocket.StreamedBinary body ->
            W.readPatternBody body

        WebSocket.StreamedText _ ->
            Task.fail "expected a binary message"


textBody : WebSocket.StreamedMessage -> Task String String
textBody m =
    case m of
        WebSocket.StreamedText body ->
            W.readTextBody body |> Task.map (\( chunks, _ ) -> String.concat chunks)

        WebSocket.StreamedBinary _ ->
            Task.fail "expected a text message"


readEnd : WebSocket.WebSocket WebSocket.Streamed -> Task x String
readEnd ws =
    Stream.read (WebSocket.streamedReadable ws)
        |> Task.map (\_ -> "a message")
        |> Task.onError (\e -> Task.succeed (Stream.errorToString e))


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                H.async (W.acceptStreamed listener |> Task.andThen (\ws -> serve ws |> Task.map (\end -> ( ws, end ))))
                    |> Task.andThen
                        (\serverDone ->
                            W.connectStreamed W.noCompression listener
                                |> Task.andThen
                                    (\client ->
                                        W.patternSource 1600 65536
                                            |> Task.andThen (\source -> H.async (WebSocket.sendBinary source client |> Task.mapError W.wsErr))
                                            |> Task.andThen
                                                (\sent ->
                                                    nextBody client
                                                        |> Task.andThen binaryBody
                                                        |> Task.andThen (\big -> sent |> Task.map (\_ -> big))
                                                )
                                            |> Task.andThen (\big -> step2 client |> Task.map (\rest -> ( big, rest )))
                                            |> Task.andThen
                                                (\( ( bigSize, bigOk ), ( text, ( emptySize, emptyOk ) ) ) ->
                                                    WebSocket.close WebSocket.Normal "done" client
                                                        |> Task.mapError W.wsErr
                                                        |> Task.andThen (\_ -> readEnd client)
                                                        |> Task.andThen
                                                            (\clientEnd ->
                                                                serverDone
                                                                    |> Task.andThen
                                                                        (\( server, serverEnd ) ->
                                                                            Task.map2
                                                                                (\ci si ->
                                                                                    [ "big echoed: " ++ String.fromInt bigSize ++ " bytes, pattern " ++ H.boolString bigOk
                                                                                    , "text echoed: Text \"" ++ text ++ "\""
                                                                                    , "empty echoed: " ++ String.fromInt emptySize ++ " bytes, pattern " ++ H.boolString emptyOk
                                                                                    , "client end: " ++ clientEnd
                                                                                    , "server end: " ++ serverEnd
                                                                                    , "client closed: " ++ W.closeInfoString ci
                                                                                    , "server closed: " ++ W.closeInfoString si
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


{-| A streamed text message in three chunks, then an empty streamed binary message.
-}
step2 : WebSocket.WebSocket WebSocket.Streamed -> Task String ( String, ( Int, Bool ) )
step2 client =
    Stream.fromList [ "héllo ", "wörld", " ✓" ]
        |> Task.mapError Stream.errorToString
        |> Task.andThen (\source -> WebSocket.sendText source client |> Task.mapError W.wsErr)
        |> Task.andThen (\_ -> nextBody client)
        |> Task.andThen textBody
        |> Task.andThen
            (\text ->
                Stream.fromList []
                    |> Task.mapError Stream.errorToString
                    |> Task.andThen (\source -> WebSocket.sendBinary source client |> Task.mapError W.wsErr)
                    |> Task.andThen (\_ -> nextBody client)
                    |> Task.andThen binaryBody
                    |> Task.map (\empty -> ( text, empty ))
            )
