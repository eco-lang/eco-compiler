module WebSocketSendStreamInterleaveTest exposing (main)

{-| Sending a message from a stream (plans/eco-system-websockets.md §4 WS6, W7): a client sends a
text message with `sendText` from a stream it writes into by hand, against a raw server that
watches the frames. The stream's chunks go out as fragments as they are written (the first one as
a non-final text frame); the raw server sends a ping in the middle of the message and gets its
pong at once; a message written to the writable meanwhile is sent after the streamed message ends
(the end of the stream is a final, empty continuation frame).
-}

-- CHECK: send: ok
-- CHECK: during: ok
-- CHECK: raw server got: text "part1" | pong FIN [9,9] | cont "part2" | cont FIN "" | text FIN "during" | close FIN 1000
-- EXIT: 0

import Bytes exposing (Bytes)
import Process
import Socket
import SocketTestHelp as H
import Stream
import System
import Task exposing (Task)
import WebSocket
import WebSocketSha1 exposing (acceptFor)
import WebSocketTestHelp as W


main : System.SimpleProgram ()
main =
    H.program run


{-| Read until the frames received so far satisfy `done`.
-}
readUntil : Socket.Connection -> Bytes -> (List ( ( Bool, Bool ), Int, List Int ) -> Bool) -> Task String Bytes
readUntil conn acc done =
    if done (W.parseFramesFin acc) then
        Task.succeed acc

    else
        W.rawRead conn |> Task.andThen (\chunk -> readUntil conn (W.concatBytes acc chunk) done)


has : Int -> List ( ( Bool, Bool ), Int, List Int ) -> Bool
has op frames =
    List.any (\( _, o, _ ) -> o == op) frames


rawServer : Socket.Listener -> Stream.Writable () -> Task String String
rawServer listener signal =
    W.rawUpgradeClient listener (\key -> W.switching acceptFor key [])
        |> Task.andThen
            (\( conn, _ ) ->
                readUntil conn (W.bytesOfList []) (has 1)
                    |> Task.andThen (\acc -> W.rawWrite (W.frame True 0 9 (W.bytesOfList [ 9, 9 ])) conn |> Task.map (\_ -> acc))
                    |> Task.andThen (\acc -> readUntil conn acc (has 10))
                    |> Task.andThen (\acc -> Stream.write () signal |> Task.mapError Stream.errorToString |> Task.map (\_ -> acc))
                    |> Task.andThen (\acc -> readUntil conn acc (has 8))
                    |> Task.andThen
                        (\acc ->
                            W.rawWrite (W.frame True 0 8 (W.closePayload 1000 "")) conn
                                |> Task.andThen (\_ -> H.socketErr (Socket.close conn))
                                |> Task.map (\_ -> W.framesFinString (W.parseFramesFin acc))
                        )
            )


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                Task.map2 Tuple.pair Stream.identityTransformation Stream.identityTransformation
                    |> Task.andThen
                        (\( signal, source ) ->
                            H.async (rawServer listener (Stream.writable signal))
                                |> Task.andThen
                                    (\rawDone ->
                                        W.connect listener
                                            |> Task.andThen
                                                (\client ->
                                                    H.async (WebSocket.sendText (Stream.readable source) client |> Task.mapError W.wsErr)
                                                        |> Task.andThen
                                                            (\sending ->
                                                                Stream.write "part1" (Stream.writable source)
                                                                    |> Task.mapError Stream.errorToString
                                                                    |> Task.andThen (\_ -> Stream.read (Stream.readable signal) |> Task.mapError Stream.errorToString)
                                                                    |> Task.andThen (\_ -> H.async (W.sendAll [ W.text "during" ] client))
                                                                    |> Task.andThen
                                                                        (\during ->
                                                                            Process.sleep 100
                                                                                |> Task.andThen (\_ -> W.writeAll [ "part2" ] (Stream.writable source))
                                                                                |> Task.andThen (\_ -> sending)
                                                                                |> Task.andThen (\_ -> during)
                                                                        )
                                                                    |> Task.andThen (\_ -> WebSocket.close WebSocket.Normal "" client |> Task.mapError W.wsErr)
                                                                    |> Task.andThen (\_ -> rawDone)
                                                                    |> Task.map
                                                                        (\frames ->
                                                                            [ "send: ok"
                                                                            , "during: ok"
                                                                            , "raw server got: " ++ frames
                                                                            ]
                                                                        )
                                                            )
                                                )
                                    )
                        )
                    |> Task.andThen
                        (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )
