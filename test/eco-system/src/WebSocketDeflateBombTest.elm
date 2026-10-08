module WebSocketDeflateBombTest exposing (main)

{-| Compression bombs (plans/eco-system-websockets.md §4 WS7, §3.7: bounded inflate). A raw client
negotiates permessage-deflate and sends a compressed message that would inflate to about 1 GiB of
zeros (a fixed-Huffman DEFLATE block repeating "copy 258 bytes from distance 1": about 158 bytes
out per byte in, 6.6 MB in all, sent in 65 KB frames).

  - Whole mode (maxMessageSize 16 MiB): the server inflates in steps of at most 64 KiB and fails
    the connection with 1009 as soon as the message passes 16 MiB, long before the end; the
    process grows by less than 64 MiB (measured on a second run: the first one warms up, as
    some heap configurations grow the heap once at the first collections).
  - Streamed mode (no size limit): a 200 MiB bomb whose body the server leaves unread for a
    second — inflating stops while the body is full and TCP pushes back — then cancels: the rest
    is still inflated (to keep the stream in sync) and dropped as it arrives, and the next message
    arrives intact. The process stays within 32 MiB.

(DEFLATE cannot reach the ratio of "1 KiB to 1 GiB"; its ceiling is about 1 032:1.)
-}

-- CHECK: whole: end Cancelled: ERR_WS_MESSAGE_TOO_BIG; closed MessageTooBig "the message is larger than maxMessageSize" clean False; raw client got close 1009; bounded True
-- CHECK: streamed: stalled bounded True; after cancel bounded True; next Text "after"; end Closed
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Encode as E
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


{-| The first bytes of the stream: block header (not final, fixed Huffman), a literal 0, and the
start of the first repeat.
-}
head : List Int
head =
    [ 98, 24 ]


{-| Thirteen bytes = eight "length 258, distance 1" codes (2 064 bytes out).
-}
period : List Int
period =
    [ 5, 163, 96, 20, 140, 130, 81, 48, 10, 70, 193, 40, 24 ]


{-| The rest of the last code, the end-of-block code and an empty stored block's header (the
receiver appends 00 00 ff ff).
-}
tail : List Int
tail =
    [ 5, 0, 0 ]


periods : Bytes
periods =
    E.encode (E.sequence (List.repeat 5000 (E.bytes (W.bytesOfList period))))


firstFrame : Bytes
firstFrame =
    W.zeroMaskedFrame False 4 2 (E.encode (E.sequence [ E.bytes (W.bytesOfList head), E.bytes periods ]))


nextFrame : Bytes
nextFrame =
    W.zeroMaskedFrame False 0 0 periods


{-| Write frames until `n` were written or a write fails (the server went away).
-}
writeFrames : Socket.Connection -> Int -> Task x ()
writeFrames conn n =
    if n <= 0 then
        Task.succeed ()

    else
        W.rawWrite nextFrame conn
            |> Task.map (\_ -> True)
            |> Task.onError (\_ -> Task.succeed False)
            |> Task.andThen
                (\ok ->
                    if ok then
                        writeFrames conn (n - 1)

                    else
                        Task.succeed ()
                )


wholeCase : Socket.Listener -> Task String String
wholeCase listener =
    W.rssKiB
        |> Task.andThen
            (\rss0 ->
                H.async (W.acceptOne listener |> Task.andThen (\ws -> W.readAll ws |> Task.andThen (\( _, end ) -> WebSocket.closed ws |> Task.map (\info -> ( end, info )))))
                    |> Task.andThen
                        (\serverDone ->
                            W.rawHandshakeHead listener [ "Sec-WebSocket-Extensions: permessage-deflate" ] firstFrame
                                |> Task.andThen
                                    (\( conn, _, rest ) ->
                                        writeFrames conn 102
                                            |> Task.andThen (\_ -> W.rawReadAll conn)
                                            |> Task.map (W.concatBytes rest)
                                            |> Task.andThen
                                                (\received ->
                                                    serverDone
                                                        |> Task.andThen
                                                            (\( end, info ) ->
                                                                W.rssKiB
                                                                    |> Task.map
                                                                        (\rss1 ->
                                                                            "whole: end "
                                                                                ++ end
                                                                                ++ "; closed "
                                                                                ++ W.closeInfoString info
                                                                                ++ "; raw client got "
                                                                                ++ String.join " | " (List.map closeOnly (W.parseFrames received))
                                                                                ++ "; bounded "
                                                                                ++ H.boolString (rss1 - rss0 < 64 * 1024)
                                                                                ++ " ("
                                                                                ++ String.fromInt (rss1 - rss0)
                                                                                ++ " KiB)"
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


closeOnly : ( Int, List Int ) -> String
closeOnly ( op, payload ) =
    case ( op, payload ) of
        ( 8, hi :: lo :: _ ) ->
            "close " ++ String.fromInt (hi * 256 + lo)

        _ ->
            "op " ++ String.fromInt op


streamedCase : Socket.Listener -> Task String String
streamedCase listener =
    H.async (W.acceptStreamed listener)
        |> Task.andThen
            (\accepted ->
                W.rawHandshakeHead listener [ "Sec-WebSocket-Extensions: permessage-deflate" ] (W.bytesOfList [])
                    |> Task.andThen
                        (\( conn, _, _ ) ->
                            accepted
                                |> Task.andThen
                                    (\server ->
                                        W.rssKiB
                                            |> Task.andThen
                                                (\rss0 ->
                                                    H.async
                                                        (W.rawWrite firstFrame conn
                                                            |> Task.andThen (\_ -> writeFrames conn 19)
                                                            |> Task.andThen (\_ -> W.rawWrite (W.zeroMaskedFrame True 0 0 (W.bytesOfList tail)) conn)
                                                            |> Task.andThen (\_ -> W.rawWrite (W.zeroMaskedFrame True 0 1 (H.bytesOf "after")) conn)
                                                        )
                                                        |> Task.andThen
                                                            (\written ->
                                                                Stream.read (WebSocket.streamedReadable server)
                                                                    |> Task.mapError Stream.errorToString
                                                                    |> Task.andThen
                                                                        (\m ->
                                                                            Process.sleep 1000
                                                                                |> Task.andThen (\_ -> W.rssKiB)
                                                                                |> Task.andThen
                                                                                    (\rss1 ->
                                                                                        (case m of
                                                                                            WebSocket.StreamedBinary body ->
                                                                                                Stream.cancelReadable "bomb" body |> Task.mapError Stream.errorToString

                                                                                            WebSocket.StreamedText _ ->
                                                                                                Task.fail "expected binary"
                                                                                        )
                                                                                            |> Task.andThen (\_ -> written)
                                                                                            |> Task.andThen (\_ -> Stream.read (WebSocket.streamedReadable server) |> Task.mapError Stream.errorToString)
                                                                                            |> Task.andThen
                                                                                                (\next ->
                                                                                                    case next of
                                                                                                        WebSocket.StreamedText body ->
                                                                                                            W.readTextBody body |> Task.map (\( chunks, _ ) -> String.concat chunks)

                                                                                                        WebSocket.StreamedBinary _ ->
                                                                                                            Task.succeed "binary?"
                                                                                                )
                                                                                            |> Task.andThen
                                                                                                (\after ->
                                                                                                    W.rssKiB
                                                                                                        |> Task.andThen
                                                                                                            (\rss2 ->
                                                                                                                W.rawWrite (W.maskedFrame True 0 8 (W.closePayload 1000 "")) conn
                                                                                                                    |> Task.andThen (\_ -> W.rawReadAll conn)
                                                                                                                    |> Task.andThen
                                                                                                                        (\_ ->
                                                                                                                            Stream.read (WebSocket.streamedReadable server)
                                                                                                                                |> Task.map (\_ -> "a message")
                                                                                                                                |> Task.onError (\e -> Task.succeed (Stream.errorToString e))
                                                                                                                        )
                                                                                                                    |> Task.map
                                                                                                                        (\end ->
                                                                                                                            "streamed: stalled bounded "
                                                                                                                                ++ H.boolString (rss1 - rss0 < 32 * 1024)
                                                                                                                                ++ "; after cancel bounded "
                                                                                                                                ++ H.boolString (rss2 - rss0 < 32 * 1024)
                                                                                                                                ++ "; next Text \""
                                                                                                                                ++ after
                                                                                                                                ++ "\"; end "
                                                                                                                                ++ end
                                                                                                                                ++ " ("
                                                                                                                                ++ String.fromInt (rss1 - rss0)
                                                                                                                                ++ ", "
                                                                                                                                ++ String.fromInt (rss2 - rss0)
                                                                                                                                ++ " KiB)"
                                                                                                                        )
                                                                                                            )
                                                                                                )
                                                                                    )
                                                                        )
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
                -- The first run warms up (some heap configurations grow the heap once, at the
                -- first collections); the second is the one measured.
                wholeCase listener
                    |> Task.andThen (\_ -> wholeCase listener)
                    |> Task.andThen (\whole -> streamedCase listener |> Task.map (\streamed -> [ whole, streamed ]))
                    |> Task.andThen (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )
