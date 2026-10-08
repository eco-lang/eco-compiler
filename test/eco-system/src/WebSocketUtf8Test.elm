module WebSocketUtf8Test exposing (main)

{-| UTF-8 in text messages and close reasons (plans/eco-system-websockets.md §4 WS4, Appendix D.4,
D.5): invalid text fails the connection with 1007, and so does a fragment whose bytes cannot start
valid UTF-8: the server fails at once, before the message ends (the raw client sends nothing
more); a sequence cut by the end of the message fails too, while a character split across
fragments is fine; an invalid close reason fails with 1007.
-}

-- CHECK: invalid text: server Cancelled: ERR_WS_INVALID_DATA: invalid UTF-8 in a text message | InvalidData "invalid UTF-8 in a text message" clean False | raw close 1007
-- CHECK: fail fast: server Cancelled: ERR_WS_INVALID_DATA: invalid UTF-8 in a text message | InvalidData
-- CHECK: fail at next fragment: server Cancelled: ERR_WS_INVALID_DATA: invalid UTF-8 in a text message | InvalidData
-- CHECK: cut at the end: server Cancelled: ERR_WS_INVALID_DATA: invalid UTF-8 in a text message | InvalidData
-- CHECK: split character: server got Text "𝄞é" then Closed | Normal "" clean True | raw close 1000 ""
-- CHECK: invalid close reason: server Cancelled: ERR_WS_INVALID_DATA: the close reason is not valid UTF-8 | InvalidData "the close reason is not valid UTF-8" clean False | raw close 1007
-- EXIT: 0

import Bytes exposing (Bytes)
import Socket
import SocketTestHelp as H
import System
import Task exposing (Task)
import WebSocket
import WebSocketTestHelp as W


main : System.SimpleProgram ()
main =
    H.program run


close : Bytes
close =
    W.maskedFrame True 0 8 (W.closePayload 1000 "")


cases : List ( String, Bytes )
cases =
    [ ( "invalid text", W.maskedFrame True 0 1 (W.bytesOfList [ 0x61, 0xC3, 0x28 ]) )
    , ( "fail fast", W.maskedFrame False 0 1 (W.bytesOfList [ 0x61, 0xFF ]) )
    , ( "fail at next fragment", W.concatBytes (W.maskedFrame False 0 1 (W.bytesOfList [ 0x61, 0xE2, 0x82 ])) (W.maskedFrame False 0 0 (W.bytesOfList [ 0x28 ])) )
    , ( "cut at the end", W.maskedFrame True 0 1 (W.bytesOfList [ 0x61, 0xE2, 0x82 ]) )
    , ( "split character"
      , List.foldl (\b acc -> W.concatBytes acc b)
            (W.maskedFrame False 0 1 (W.bytesOfList [ 0xF0, 0x9D ]))
            [ W.maskedFrame False 0 0 (W.bytesOfList [ 0x84, 0x9E, 0xC3 ]), W.maskedFrame True 0 0 (W.bytesOfList [ 0xA9 ]), close ]
      )
    , ( "invalid close reason", W.maskedFrame True 0 8 (W.concatBytes (W.closePayload 1000 "") (W.bytesOfList [ 0xFF ])) )
    ]


serverCase : Socket.Listener -> ( String, Bytes ) -> Task String String
serverCase listener ( label, bytes ) =
    H.async
        (W.acceptOne listener
            |> Task.andThen (\ws -> W.readAll ws |> Task.andThen (\( got, end ) -> WebSocket.closed ws |> Task.map (\info -> ( got, end, info ))))
        )
        |> Task.andThen
            (\serverDone ->
                W.rawHandshake listener [] bytes
                    |> Task.andThen (\( conn, _, early ) -> W.rawReadAll conn |> Task.map (W.concatBytes early))
                    |> Task.andThen
                        (\received ->
                            serverDone
                                |> Task.map
                                    (\( got, end, info ) ->
                                        label
                                            ++ ": server "
                                            ++ (if List.isEmpty got then
                                                    end

                                                else
                                                    "got " ++ String.join " | " (List.map W.messageString got) ++ " then " ++ end
                                               )
                                            ++ " | "
                                            ++ W.closeInfoString info
                                            ++ " | raw "
                                            ++ W.framesString (W.parseFrames received)
                                    )
                        )
            )


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                List.map (serverCase listener) cases
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
