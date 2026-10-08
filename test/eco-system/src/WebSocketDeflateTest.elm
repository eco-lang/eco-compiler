module WebSocketDeflateTest exposing (main)

{-| permessage-deflate on the wire (plans/eco-system-websockets.md §4 WS7, §3.7, Appendix D.7), with
raw clients against our server:

  - inbound: the RFC 7692 §7.2.3 examples (one block, a stored block, a block with BFINAL, two
    blocks, a fragmented message with RSV1 on its first frame only), an uncompressed message in
    between (RSV1 is per message) and an empty compressed message all arrive as "Hello" / "plain"
    / "";
  - outbound with context takeover (policy `contextTakeover = True`, threshold 0): "Hello" twice
    is `f2 48 cd c9 c9 07 00`, then `f2 00 11 00 00` (§7.2.3.2);
  - outbound with the default policy (no context takeover, threshold 64): short messages go
    uncompressed; two equal 100-byte messages compress to the same bytes;
  - window bits: an offer of `server_max_window_bits=8` is answered with 8 (zlib deflates with 9);
  - declined: a server without compression answers no extension and sends plain frames;
  - RSV1 on a continuation frame fails the connection with 1002.

-}

-- CHECK: inbound: offer answered permessage-deflate; server_no_context_takeover; client_no_context_takeover
-- CHECK: inbound: Text "Hello" | Text "Hello" | Text "plain" | Text "Hello" | Text "Hello" | Text "Hello" | Text "" | end Closed
-- CHECK: takeover: answered permessage-deflate; frames text FIN Z f2 48 cd c9 c9 07 00 | text FIN Z f2 00 11 00 00 | close FIN 03 e8
-- CHECK: default: answered permessage-deflate; server_no_context_takeover; client_no_context_takeover; short plain True; long compressed True; same bytes True
-- CHECK: window 8: answered permessage-deflate; server_no_context_takeover; client_no_context_takeover; server_max_window_bits=8; compressed True
-- CHECK: declined: answered none; plain True
-- CHECK: rsv1 on a continuation: end Cancelled: ERR_WS_PROTOCOL: RSV1 is set on a continuation frame; raw client got close 1002
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


type alias Frame =
    ( ( Bool, Bool ), Int, List Int )


hello : List Int
hello =
    [ 0xF2, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00 ]


long : String
long =
    String.repeat 100 "x"


hex : List Int -> String
hex bytes =
    bytes
        |> List.map
            (\n ->
                let
                    digit d =
                        String.slice d (d + 1) "0123456789abcdef"
                in
                digit (n // 16) ++ digit (modBy 16 n)
            )
        |> String.join " "


frameHex : Frame -> String
frameHex ( ( fin, rsv1 ), op, payload ) =
    (case op of
        1 ->
            "text"

        2 ->
            "binary"

        8 ->
            "close"

        _ ->
            "op " ++ String.fromInt op
    )
        ++ (if fin then
                " FIN"

            else
                ""
           )
        ++ (if rsv1 then
                " Z"

            else
                ""
           )
        ++ " "
        ++ hex payload


isData : Frame -> Bool
isData ( _, op, _ ) =
    op == 1 || op == 2 || op == 0


readUntil : Socket.Connection -> Bytes -> (List Frame -> Bool) -> Task String Bytes
readUntil conn acc done =
    if done (W.parseFramesFin acc) then
        Task.succeed acc

    else
        W.rawRead conn |> Task.andThen (\chunk -> readUntil conn (W.concatBytes acc chunk) done)


{-| A raw client: offers `offer`, sends `frames` (built from the handshake's leftover nothing),
waits for `dataFrames` data frames from the server, closes, reads to the end. The answered
extension header and every frame received.
-}
rawClient : Socket.Listener -> String -> List Bytes -> Int -> Task String ( String, List Frame )
rawClient listener offer frames dataFrames =
    W.rawHandshakeHead listener [ "Sec-WebSocket-Extensions: " ++ offer ] (W.bytesOfList [])
        |> Task.andThen
            (\( conn, head, rest ) ->
                W.sendEach conn frames
                    |> Task.andThen (\_ -> readUntil conn rest (\fs -> List.length (List.filter isData fs) >= dataFrames))
                    |> Task.andThen
                        (\acc ->
                            W.rawWrite (W.maskedFrame True 0 8 (W.closePayload 1000 "")) conn
                                |> Task.onError (\_ -> Task.succeed ())
                                |> Task.andThen (\_ -> W.rawReadAll conn)
                                |> Task.map (\more -> ( W.headerOf "Sec-WebSocket-Extensions" head, W.parseFramesFin (W.concatBytes acc more) ))
                        )
            )


compressed : List Int -> Bytes
compressed payload =
    W.bytesOfList payload


serverWith : WebSocket.AcceptOptions -> Socket.Listener -> (WebSocket.WebSocket WebSocket.Whole -> Task String a) -> Task x (Task String ( a, String ))
serverWith options listener act =
    H.async
        (W.acceptWith options listener
            |> Task.andThen (\ws -> act ws |> Task.andThen (\a -> W.readAll ws |> Task.map (\( _, end ) -> ( a, end ))))
        )


withCompression : Maybe WebSocket.ServerCompression -> WebSocket.AcceptOptions
withCompression c =
    let
        d =
            WebSocket.defaultAcceptOptions
    in
    { d | compression = c }


inboundCase : Socket.Listener -> Task String (List String)
inboundCase listener =
    serverWith WebSocket.defaultAcceptOptions listener (W.readMessages 7)
        |> Task.andThen
            (\serverDone ->
                rawClient listener
                    "permessage-deflate"
                    [ W.zeroMaskedFrame True 4 1 (compressed hello)
                    , W.zeroMaskedFrame True 4 1 (compressed [ 0x00, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00 ])
                    , W.zeroMaskedFrame True 0 1 (H.bytesOf "plain")
                    , W.zeroMaskedFrame True 4 1 (compressed [ 0xF3, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00, 0x00 ])
                    , W.zeroMaskedFrame True 4 1 (compressed [ 0xF2, 0x48, 0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xCA, 0xC9, 0xC9, 0x07, 0x00 ])
                    , W.zeroMaskedFrame False 4 1 (compressed [ 0xF2, 0x48, 0xCD ])
                    , W.zeroMaskedFrame True 0 0 (compressed [ 0xC9, 0xC9, 0x07, 0x00 ])
                    , W.zeroMaskedFrame True 4 1 (compressed [ 0x00 ])
                    ]
                    0
                    |> Task.andThen
                        (\( answered, _ ) ->
                            serverDone
                                |> Task.map
                                    (\( got, end ) ->
                                        [ "inbound: offer answered " ++ answered
                                        , "inbound: " ++ String.join " | " (List.map W.messageString got) ++ " | end " ++ end
                                        ]
                                    )
                        )
            )


takeoverCase : Socket.Listener -> Task String (List String)
takeoverCase listener =
    serverWith (withCompression (Just { maxWindowBits = 15, contextTakeover = True, threshold = 0 })) listener (W.sendAll [ W.text "Hello", W.text "Hello" ])
        |> Task.andThen
            (\serverDone ->
                rawClient listener "permessage-deflate" [] 2
                    |> Task.andThen
                        (\( answered, frames ) ->
                            serverDone
                                |> Task.map
                                    (\_ -> [ "takeover: answered " ++ answered ++ "; frames " ++ String.join " | " (List.map frameHex frames) ])
                        )
            )


payloadOf : Frame -> List Int
payloadOf ( _, _, p ) =
    p


rsv1Of : Frame -> Bool
rsv1Of ( ( _, z ), _, _ ) =
    z


defaultCase : Socket.Listener -> Task String (List String)
defaultCase listener =
    serverWith WebSocket.defaultAcceptOptions listener (W.sendAll [ W.text "Hello", W.text "Hello", W.text long, W.text long ])
        |> Task.andThen
            (\serverDone ->
                rawClient listener "permessage-deflate; client_max_window_bits" [] 4
                    |> Task.andThen
                        (\( answered, frames ) ->
                            let
                                data =
                                    List.filter isData frames
                            in
                            serverDone
                                |> Task.map
                                    (\_ ->
                                        [ "default: answered "
                                            ++ answered
                                            ++ "; short plain "
                                            ++ H.boolString (List.map rsv1Of (List.take 2 data) == [ False, False ] && List.map payloadOf (List.take 2 data) == [ [ 72, 101, 108, 108, 111 ], [ 72, 101, 108, 108, 111 ] ])
                                            ++ "; long compressed "
                                            ++ H.boolString (List.map rsv1Of (List.drop 2 data) == [ True, True ] && List.all (\f -> List.length (payloadOf f) < 100) (List.drop 2 data))
                                            ++ "; same bytes "
                                            ++ H.boolString
                                                (case List.drop 2 data of
                                                    [ a, b ] ->
                                                        payloadOf a == payloadOf b

                                                    _ ->
                                                        False
                                                )
                                        ]
                                    )
                        )
            )


windowCase : Socket.Listener -> Task String (List String)
windowCase listener =
    serverWith WebSocket.defaultAcceptOptions listener (W.sendAll [ W.text (String.repeat 50 "window bits ") ])
        |> Task.andThen
            (\serverDone ->
                rawClient listener "permessage-deflate; server_max_window_bits=8" [] 1
                    |> Task.andThen
                        (\( answered, frames ) ->
                            serverDone
                                |> Task.map
                                    (\_ ->
                                        [ "window 8: answered "
                                            ++ answered
                                            ++ "; compressed "
                                            ++ H.boolString (List.map rsv1Of (List.filter isData frames) == [ True ])
                                        ]
                                    )
                        )
            )


declinedCase : Socket.Listener -> Task String (List String)
declinedCase listener =
    serverWith (withCompression Nothing) listener (W.sendAll [ W.text long ])
        |> Task.andThen
            (\serverDone ->
                rawClient listener "permessage-deflate" [] 1
                    |> Task.andThen
                        (\( answered, frames ) ->
                            serverDone
                                |> Task.map
                                    (\_ ->
                                        [ "declined: answered "
                                            ++ answered
                                            ++ "; plain "
                                            ++ H.boolString (List.map (\f -> ( rsv1Of f, List.length (payloadOf f) )) (List.filter isData frames) == [ ( False, 100 ) ])
                                        ]
                                    )
                        )
            )


rsv1Case : Socket.Listener -> Task String (List String)
rsv1Case listener =
    serverWith WebSocket.defaultAcceptOptions listener (\_ -> Task.succeed ())
        |> Task.andThen
            (\serverDone ->
                W.rawHandshakeHead listener [ "Sec-WebSocket-Extensions: permessage-deflate" ] (W.bytesOfList [])
                    |> Task.andThen
                        (\( conn, _, rest ) ->
                            W.sendEach conn
                                [ W.zeroMaskedFrame False 0 1 (H.bytesOf "a")
                                , W.zeroMaskedFrame True 4 0 (H.bytesOf "b")
                                ]
                                |> Task.andThen (\_ -> W.rawReadAll conn)
                                |> Task.map (W.concatBytes rest)
                                |> Task.andThen
                                    (\received ->
                                        serverDone
                                            |> Task.map
                                                (\( _, end ) ->
                                                    [ "rsv1 on a continuation: end " ++ end ++ "; raw client got " ++ String.join " | " (List.map closeOnly (W.parseFrames received)) ]
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


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                [ inboundCase, takeoverCase, defaultCase, windowCase, declinedCase, rsv1Case ]
                    |> List.map (\c -> c listener)
                    |> sequence
                    |> Task.map List.concat
                    |> Task.andThen (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )


sequence : List (Task String a) -> Task String (List a)
sequence tasks =
    case tasks of
        [] ->
            Task.succeed []

        t :: rest ->
            t |> Task.andThen (\x -> sequence rest |> Task.map ((::) x))
