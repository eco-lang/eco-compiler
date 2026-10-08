module WebSocketHandshakeServerTest exposing (main)

{-| The server side of the opening handshake (plans/eco-system-websockets.md §4 WS4, Appendix D.3),
with raw clients over `Socket.Tcp`: a POST, a request without `Sec-WebSocket-Key`, a key of 20 bytes
and a request for another HTTP version are answered 400 by `accept` (which fails
`ERR_WS_HANDSHAKE`); `Sec-WebSocket-Version: 8` is answered 426 with `Sec-WebSocket-Version: 13`;
the protocol the server picks among the offered ones is returned; a protocol that was not offered
fails `accept` with `EINVAL` and leaves the request to `reject`, which answers with its status,
headers and body and closes. `upgradeTarget`, `upgradeProtocols`, `upgradeOrigin` and
`upgradeHeaders` describe the request.
-}

-- CHECK: post: server err ERR_WS_HANDSHAKE handshakeFailed True | client HTTP/1.1 400 Bad Request
-- CHECK: no key: server err ERR_WS_HANDSHAKE handshakeFailed True | client HTTP/1.1 400 Bad Request
-- CHECK: 20-byte key: server err ERR_WS_HANDSHAKE handshakeFailed True | client HTTP/1.1 400 Bad Request
-- CHECK: http/1.0: server err ERR_WS_HANDSHAKE handshakeFailed True | client HTTP/1.1 400 Bad Request
-- CHECK: version 8: server err ERR_WS_HANDSHAKE handshakeFailed True | client HTTP/1.1 426 Upgrade Required version 13
-- CHECK: protocols: server ok target /chat?room=1 protocols chat,superchat origin http://example.com upgrade websocket chosen superchat | client HTTP/1.1 101 Switching Protocols protocol superchat accept s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
-- CHECK: not offered: server err EINVAL, rejected | client HTTP/1.1 403 Forbidden x-why nope body no thanks
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


crlf : List String -> String
crlf lines =
    String.join "\u{000D}\n" lines ++ "\u{000D}\n\u{000D}\n"


requestWith : String -> List String -> String
requestWith requestLine headers =
    crlf (requestLine :: "Host: 127.0.0.1" :: headers)


standard : List String
standard =
    [ "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" ]


cases : List ( String, String, WebSocket.Upgrade -> Task Never String )
cases =
    [ ( "post", requestWith "POST /x HTTP/1.1" (standard ++ [ "Sec-WebSocket-Version: 13" ]), acceptDefault )
    , ( "no key", requestWith "GET /x HTTP/1.1" [ "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Version: 13" ], acceptDefault )
    , ( "20-byte key"
      , requestWith "GET /x HTTP/1.1" [ "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAAAAAAA=", "Sec-WebSocket-Version: 13" ]
      , acceptDefault
      )
    , ( "http/1.0", requestWith "GET /x HTTP/1.0" (standard ++ [ "Sec-WebSocket-Version: 13" ]), acceptDefault )
    , ( "version 8", requestWith "GET /x HTTP/1.1" (standard ++ [ "Sec-WebSocket-Version: 8" ]), acceptDefault )
    , ( "protocols"
      , requestWith "GET /chat?room=1 HTTP/1.1"
            (standard ++ [ "Sec-WebSocket-Version: 13", "Sec-WebSocket-Protocol: chat", "sec-websocket-protocol: superchat", "Origin: http://example.com" ])
      , acceptProtocol
      )
    , ( "not offered", requestWith "GET /x HTTP/1.1" (standard ++ [ "Sec-WebSocket-Version: 13", "Sec-WebSocket-Protocol: chat" ]), acceptOther )
    ]


acceptDefault : WebSocket.Upgrade -> Task Never String
acceptDefault up =
    WebSocket.accept WebSocket.defaultAcceptOptions up
        |> Task.map (\_ -> "server ok")
        |> Task.onError
            (\e ->
                Task.succeed
                    ("server err " ++ Socket.errorCode e ++ " handshakeFailed " ++ H.boolString (WebSocket.errorIsHandshakeFailed e))
            )


acceptProtocol : WebSocket.Upgrade -> Task Never String
acceptProtocol up =
    let
        options =
            WebSocket.defaultAcceptOptions

        describeUp =
            "target "
                ++ WebSocket.upgradeTarget up
                ++ " protocols "
                ++ String.join "," (WebSocket.upgradeProtocols up)
                ++ " origin "
                ++ Maybe.withDefault "-" (WebSocket.upgradeOrigin up)
                ++ " upgrade "
                ++ (WebSocket.upgradeHeaders up |> List.filter (\( n, _ ) -> n == "upgrade") |> List.map Tuple.second |> String.join ",")
    in
    WebSocket.accept { options | protocol = Just "superchat" } up
        |> Task.andThen
            (\ws ->
                W.readAll ws
                    |> Task.map (\_ -> "server ok " ++ describeUp ++ " chosen " ++ Maybe.withDefault "-" (WebSocket.protocol ws))
            )
        |> Task.onError (\e -> Task.succeed ("server err " ++ Socket.errorCode e))


acceptOther : WebSocket.Upgrade -> Task Never String
acceptOther up =
    let
        options =
            WebSocket.defaultAcceptOptions
    in
    WebSocket.accept { options | protocol = Just "other" } up
        |> Task.map (\_ -> "server ok")
        |> Task.onError
            (\e ->
                WebSocket.reject 403 [ ( "X-Why", "nope" ) ] "no thanks" up
                    |> Task.map (\_ -> "server err " ++ Socket.errorCode e ++ ", rejected")
            )


{-| The response's status line and the headers the checks look at, then the body.
-}
summarize : String -> String
summarize response =
    let
        parts =
            String.split "\u{000D}\n\u{000D}\n" response

        head =
            List.head parts |> Maybe.withDefault ""

        body =
            List.drop 1 parts |> String.join ""

        lines =
            String.lines head |> List.map String.trim

        header name =
            lines
                |> List.filterMap
                    (\l ->
                        if String.startsWith (name ++ ":") (String.toLower l) then
                            Just (String.trim (String.dropLeft (String.length name + 1) l))

                        else
                            Nothing
                    )
                |> List.head

        extra label name =
            case header name of
                Just v ->
                    " " ++ label ++ " " ++ v

                Nothing ->
                    ""
    in
    (List.head lines |> Maybe.withDefault "")
        ++ extra "version" "sec-websocket-version"
        ++ extra "protocol" "sec-websocket-protocol"
        ++ extra "accept" "sec-websocket-accept"
        ++ extra "x-why" "x-why"
        ++ (if body == "" then
                ""

            else
                " body " ++ body
           )


runCase : Socket.Listener -> ( String, String, WebSocket.Upgrade -> Task Never String ) -> Task String String
runCase listener ( label, requestText, handler ) =
    H.async (W.upgrade listener |> Task.andThen (\up -> handler up |> Task.mapError never))
        |> Task.andThen
            (\serverDone ->
                H.socketErr (H.connectTo listener)
                    |> Task.andThen
                        (\conn ->
                            W.rawWrite (H.bytesOf requestText) conn
                                |> Task.andThen (\_ -> readResponse conn)
                                |> Task.andThen
                                    (\response ->
                                        serverDone
                                            |> Task.map (\s -> label ++ ": " ++ s ++ " | client " ++ summarize response)
                                    )
                        )
            )


{-| A 101 is followed by a Close from us (then the rest is read to the end); anything else is
read to the end.
-}
readResponse : Socket.Connection -> Task String String
readResponse conn =
    W.rawRead conn
        |> Task.andThen
            (\first ->
                let
                    text =
                        W.latin1 first
                in
                if String.startsWith "HTTP/1.1 101" text then
                    W.rawWrite (W.maskedFrame True 0 8 (W.closePayload 1000 "")) conn
                        |> Task.andThen (\_ -> W.rawReadAll conn)
                        |> Task.map (\_ -> text)

                else
                    W.rawReadAll conn |> Task.map (\rest -> text ++ W.latin1 rest)
            )


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                cases
                    |> List.map (runCase listener)
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
