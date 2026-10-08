module WebSocketStreamedMemoryTest exposing (main)

{-| Streamed messages use bounded memory (plans/eco-system-websockets.md §4 WS6): a 100 MiB
message streamed each way, measured by the process's resident set size (VmRSS, read from
/proc/self/status with `System.File`).

  - The client sends 100 MiB with `sendBinary` from a generated stream; the server takes the
    message (its body) but does not read it for 1.5 s. Reading pauses once a little is buffered,
    TCP pushes back, and the sender stalls: the process grows by less than 32 MiB.
  - The server cancels the body: the rest of the message is discarded as it arrives and the
    `sendBinary` task completes; the process is still within 32 MiB of where it started.
  - The same from the server to the client.
  - Each direction is run once with 8 MiB first, unmeasured, so that warming up (the JS engine
    sizing its heap and compiling) is not counted.
  - The connection is fine afterwards (a whole message written to the writable arrives as a
    streamed text message), and closes cleanly.

The received chunks never reach Elm here: the native runtime does not reclaim large `Bytes` values
without a major GC, which a program like this never triggers (§10 WS6), so a reader that turns
100 MiB into Elm values grows by that much whatever the WebSocket layer does
(WebSocketStreamedTest checks the 100 MiB round trip itself).
-}

-- CHECK: client to server: sent ok, stalled bounded True, after cancel bounded True
-- CHECK: server to client: sent ok, stalled bounded True, after cancel bounded True
-- CHECK: after: "after"
-- CHECK: client closed: Normal "" clean True
-- CHECK: server closed: Normal "done" clean True
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


limitKiB : Int
limitKiB =
    32 * 1024


{-| `from` sends `chunks` × 64 KiB to `to`, which leaves the body unread for 1.5 s, then cancels
it.
-}
oneWay : Int -> WebSocket.WebSocket WebSocket.Streamed -> WebSocket.WebSocket WebSocket.Streamed -> Task String String
oneWay chunks from to =
    W.rssKiB
        |> Task.andThen
            (\rss0 ->
                W.patternSource chunks 65536
                    |> Task.andThen (\source -> H.async (WebSocket.sendBinary source from |> Task.mapError W.wsErr))
                    |> Task.andThen
                        (\sent ->
                            Stream.read (WebSocket.streamedReadable to)
                                |> Task.mapError Stream.errorToString
                                |> Task.andThen
                                    (\m ->
                                        Process.sleep 1500
                                            |> Task.andThen (\_ -> W.rssKiB)
                                            |> Task.andThen
                                                (\rss1 ->
                                                    cancelBody m
                                                        |> Task.andThen (\_ -> sent)
                                                        |> Task.andThen (\_ -> W.rssKiB)
                                                        |> Task.map
                                                            (\rss2 ->
                                                                "sent ok, stalled bounded "
                                                                    ++ H.boolString (rss1 - rss0 < limitKiB)
                                                                    ++ ", after cancel bounded "
                                                                    ++ H.boolString (rss2 - rss0 < limitKiB)
                                                                    ++ " (KiB: "
                                                                    ++ String.fromInt (rss1 - rss0)
                                                                    ++ ", "
                                                                    ++ String.fromInt (rss2 - rss0)
                                                                    ++ ")"
                                                            )
                                                )
                                    )
                        )
            )


cancelBody : WebSocket.StreamedMessage -> Task String ()
cancelBody m =
    case m of
        WebSocket.StreamedBinary body ->
            Stream.cancelReadable "not needed" body |> Task.mapError Stream.errorToString

        WebSocket.StreamedText _ ->
            Task.fail "expected a binary message"


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                H.async (W.acceptStreamed listener)
                    |> Task.andThen
                        (\accepted ->
                            W.connectStreamed W.noCompression listener
                                |> Task.andThen (\client -> accepted |> Task.map (\server -> ( client, server )))
                        )
                    |> Task.andThen
                        (\( client, server ) ->
                            oneWay 128 client server
                                |> Task.andThen (\_ -> oneWay 128 server client)
                                |> Task.andThen (\_ -> oneWay 1600 client server)
                                |> Task.andThen (\c2s -> oneWay 1600 server client |> Task.map (\s2c -> ( c2s, s2c )))
                                |> Task.andThen
                                    (\( c2s, s2c ) ->
                                        Stream.write (WebSocket.Text "after") (WebSocket.writable client)
                                            |> Task.mapError Stream.errorToString
                                            |> Task.andThen (\_ -> Stream.read (WebSocket.streamedReadable server) |> Task.mapError Stream.errorToString)
                                            |> Task.andThen
                                                (\m ->
                                                    case m of
                                                        WebSocket.StreamedText body ->
                                                            W.readTextBody body |> Task.map (\( chunks, _ ) -> String.concat chunks)

                                                        WebSocket.StreamedBinary _ ->
                                                            Task.succeed "binary?"
                                                )
                                            |> Task.andThen
                                                (\after ->
                                                    WebSocket.close WebSocket.Normal "done" client
                                                        |> Task.mapError W.wsErr
                                                        |> Task.andThen
                                                            (\_ ->
                                                                Task.map2
                                                                    (\ci si ->
                                                                        [ "client to server: " ++ c2s
                                                                        , "server to client: " ++ s2c
                                                                        , "after: \"" ++ after ++ "\""
                                                                        , "client closed: " ++ W.closeInfoString ci
                                                                        , "server closed: " ++ W.closeInfoString si
                                                                        ]
                                                                    )
                                                                    (WebSocket.closed client)
                                                                    (serverEnd server |> Task.andThen (\_ -> WebSocket.closed server))
                                                            )
                                                )
                                    )
                        )
                    |> Task.andThen
                        (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )


{-| The server reads its readable to the end (the client's Close).
-}
serverEnd : WebSocket.WebSocket WebSocket.Streamed -> Task x String
serverEnd ws =
    Stream.read (WebSocket.streamedReadable ws)
        |> Task.map (\_ -> "a message")
        |> Task.onError (\e -> Task.succeed (Stream.errorToString e))
