module WebSocketCloseTimeoutTest exposing (main)

{-| The close timeout (plans/eco-system-websockets.md §4 WS4, Appendix D.5): our client sends a
Close to a raw server that never answers it; when the close timeout passes the connection is
aborted and `closed` reports `Abnormal`. The `close` task itself completes as soon as the Close is
sent. The timeout is always 30 s; the kernel test hook `ECO_WS_CLOSE_TIMEOUT_MS_FOR_TEST` cuts it
to 2 s here, so the test does not wait 30 s.
-}

-- ENV: ECO_WS_CLOSE_TIMEOUT_MS_FOR_TEST=2000
-- CHECK: close: ok
-- CHECK: raw server got: close 1000 "bye"
-- CHECK: closed: Abnormal "" clean False after the timeout True
-- CHECK: readable: Failed: socket closed
-- EXIT: 0

import Socket
import SocketTestHelp as H
import System
import Task exposing (Task)
import Time
import WebSocket
import WebSocketSha1 exposing (acceptFor)
import WebSocketTestHelp as W


main : Platform.Program System.Environment () ()
main =
    H.program run


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                H.async
                    (W.rawUpgradeClient listener
                        (\key ->
                            H.bytesOf
                                (String.join "\u{000D}\n"
                                    [ "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Accept: " ++ acceptFor key ]
                                    ++ "\u{000D}\n\u{000D}\n"
                                )
                        )
                        |> Task.andThen (\( conn, _ ) -> W.rawRead conn |> Task.map (\chunk -> ( conn, chunk )))
                    )
                    |> Task.andThen
                        (\serverDone ->
                            W.connect listener
                                |> Task.andThen
                                    (\ws ->
                                        Time.now
                                            |> Task.andThen
                                                (\t0 ->
                                                    W.describe (WebSocket.close WebSocket.Normal "bye" ws)
                                                        |> Task.andThen
                                                            (\closeResult ->
                                                                serverDone
                                                                    |> Task.andThen
                                                                        (\( conn, chunk ) ->
                                                                            WebSocket.awaitClose ws
                                                                                |> Task.andThen
                                                                                    (\info ->
                                                                                        Time.now
                                                                                            |> Task.andThen
                                                                                                (\t1 ->
                                                                                                    W.readAll ws
                                                                                                        |> Task.andThen
                                                                                                            (\( _, end ) ->
                                                                                                                H.socketErr (Socket.close conn)
                                                                                                                    |> Task.map
                                                                                                                        (\_ ->
                                                                                                                            [ "close: " ++ closeResult
                                                                                                                            , "raw server got: " ++ W.framesString (W.parseFrames chunk)
                                                                                                                            , "closed: "
                                                                                                                                ++ W.closeInfoString info
                                                                                                                                ++ " after the timeout "
                                                                                                                                ++ H.boolString (Time.posixToMillis t1 - Time.posixToMillis t0 >= 1900)
                                                                                                                            , "readable: " ++ end
                                                                                                                            ]
                                                                                                                        )
                                                                                                            )
                                                                                                )
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
                    |> Task.andThen (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )
