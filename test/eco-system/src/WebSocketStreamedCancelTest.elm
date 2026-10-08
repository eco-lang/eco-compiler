module WebSocketStreamedCancelTest exposing (main)

{-| Cancelling and cutting off streamed messages (plans/eco-system-websockets.md §4 WS6): a raw
client sends, in one go, a binary message in three 100 000-byte fragments, a text message "next",
then the first fragment of a text message and a Close. The server (`acceptStreamed`):

  - reads the first message's body once, then cancels it: the rest of the message is skipped and
    a read of the cancelled body gives `Closed`;
  - gets the next message whole ("next"), proving the skipped message was consumed exactly;
  - reads the third message's first fragment, then its body fails with `Cancelled` because the
    connection closed in the middle of it, and the server's readable ends `Closed` (a clean close).

-}

-- CHECK: first chunk: True
-- CHECK: after cancel: Closed
-- CHECK: next: next | Closed
-- CHECK: cut off: part | Cancelled: socket closed
-- CHECK: server end: Closed
-- CHECK: server closed: Normal "bye" clean True
-- CHECK: raw client got: close 1000 ""
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


fragment : Int -> Bytes
fragment n =
    E.encode (E.sequence (List.repeat n (E.unsignedInt8 42)))


next : WebSocket.WebSocket WebSocket.Streamed -> Task String WebSocket.StreamedMessage
next ws =
    Stream.read (WebSocket.streamedReadable ws) |> Task.mapError Stream.errorToString


textOf : WebSocket.StreamedMessage -> Task String String
textOf m =
    case m of
        WebSocket.StreamedText body ->
            W.readTextBody body |> Task.map (\( chunks, end ) -> String.join "" chunks ++ " | " ++ end)

        WebSocket.StreamedBinary _ ->
            Task.fail "expected text"


serve : WebSocket.WebSocket WebSocket.Streamed -> Task String (List String)
serve ws =
    next ws
        |> Task.andThen
            (\m ->
                case m of
                    WebSocket.StreamedBinary body ->
                        Stream.read body
                            |> Task.mapError Stream.errorToString
                            |> Task.andThen
                                (\chunk ->
                                    Stream.cancelReadable "skip" body
                                        |> Task.mapError Stream.errorToString
                                        |> Task.andThen
                                            (\_ ->
                                                Stream.read body
                                                    |> Task.map (\_ -> "a chunk")
                                                    |> Task.onError (\e -> Task.succeed (Stream.errorToString e))
                                            )
                                        |> Task.map (\after -> ( Bytes.width chunk > 0, after ))
                                )

                    WebSocket.StreamedText _ ->
                        Task.fail "expected binary"
            )
        |> Task.andThen
            (\( first, after ) ->
                next ws
                    |> Task.andThen textOf
                    |> Task.andThen
                        (\nextText ->
                            next ws
                                |> Task.andThen textOf
                                |> Task.andThen
                                    (\cut ->
                                        Stream.read (WebSocket.streamedReadable ws)
                                            |> Task.map (\_ -> "a message")
                                            |> Task.onError (\e -> Task.succeed (Stream.errorToString e))
                                            |> Task.andThen
                                                (\end ->
                                                    WebSocket.closed ws
                                                        |> Task.map
                                                            (\info ->
                                                                [ "first chunk: " ++ H.boolString first
                                                                , "after cancel: " ++ after
                                                                , "next: " ++ nextText
                                                                , "cut off: " ++ cut
                                                                , "server end: " ++ end
                                                                , "server closed: " ++ W.closeInfoString info
                                                                ]
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
                H.async (W.acceptStreamed listener |> Task.andThen serve)
                    |> Task.andThen
                        (\serverDone ->
                            W.rawHandshake listener [] (W.bytesOfList [])
                                |> Task.andThen
                                    (\( conn, _, early ) ->
                                        W.sendEach conn
                                            [ W.maskedFrame False 0 2 (fragment 100000)
                                            , W.maskedFrame False 0 0 (fragment 100000)
                                            , W.maskedFrame True 0 0 (fragment 100000)
                                            , W.maskedFrame True 0 1 (H.bytesOf "next")
                                            , W.maskedFrame False 0 1 (H.bytesOf "part")
                                            , W.maskedFrame True 0 8 (W.closePayload 1000 "bye")
                                            ]
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
