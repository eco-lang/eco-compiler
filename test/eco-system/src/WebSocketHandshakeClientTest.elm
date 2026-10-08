module WebSocketHandshakeClientTest exposing (main)

{-| The client side of the opening handshake (plans/eco-system-websockets.md §4 WS4, Appendix D.2),
against raw servers over `Socket.Tcp`: the request carries the D.2 headers (and the user's); a
wrong `Sec-WebSocket-Accept`, a protocol or an extension that was not offered (WS7: an unknown
extension, permessage-deflate when compression is off, or an invalid permessage-deflate answer),
a 302 (no
redirects), a response that is not HTTP and a server that closes without answering all fail
`ERR_WS_HANDSHAKE` (`handshakeStatus` gives the status when there is one); a server that never
answers fails `ETIMEDOUT` after the handshake timeout; the protocol the server chose among the
offered ones is reported. The default request offers permessage-deflate without context takeover
(WS7); a server's acceptance of it is reported by `compression`.
-}

-- CHECK: request: GET /test?x=1 HTTP/1.1 | host ok | upgrade websocket | connection Upgrade | version 13 | key 24 | origin http://example.com | extensions permessage-deflate; client_no_context_takeover; server_no_context_takeover; client_max_window_bits
-- CHECK: request without compression: extensions none
-- CHECK: bad accept: err ERR_WS_HANDSHAKE status Nothing failed True
-- CHECK: protocol not offered: err ERR_WS_HANDSHAKE status Nothing failed True
-- CHECK: extension not offered: err ERR_WS_HANDSHAKE status Nothing failed True
-- CHECK: unknown extension: err ERR_WS_HANDSHAKE status Nothing failed True
-- CHECK: invalid deflate answer: err ERR_WS_HANDSHAKE status Nothing failed True
-- CHECK: deflate accepted: ok protocol - compression True True 15 15
-- CHECK: redirect: err ERR_WS_HANDSHAKE status Just 302 failed True
-- CHECK: forbidden: err ERR_WS_HANDSHAKE status Just 403 failed True
-- CHECK: not http: err ERR_WS_HANDSHAKE status Nothing failed True
-- CHECK: closed: err ERR_WS_HANDSHAKE status Nothing failed True
-- CHECK: silent: err ETIMEDOUT status Nothing failed False
-- CHECK: chosen: ok protocol b
-- EXIT: 0

import Bytes exposing (Bytes)
import Socket
import SocketTestHelp as H
import System
import Task exposing (Task)
import WebSocket
import WebSocketSha1 exposing (acceptFor)
import WebSocketTestHelp as W


main : System.SimpleProgram ()
main =
    H.program run


crlf : List String -> String
crlf lines =
    String.join "\u{000D}\n" lines ++ "\u{000D}\n\u{000D}\n"


switching : String -> List String -> String
switching key extra =
    crlf
        ([ "HTTP/1.1 101 Switching Protocols"
         , "Upgrade: websocket"
         , "Connection: Upgrade"
         , "Sec-WebSocket-Accept: " ++ acceptFor key
         ]
            ++ extra
        )


type Server
    = Answer (String -> String)
    | CloseAtOnce
    | Silent


cases : List ( String, Server, WebSocket.ConnectOptions -> WebSocket.ConnectOptions )
cases =
    [ ( "bad accept", Answer (\_ -> crlf [ "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=" ]), identity )
    , ( "protocol not offered", Answer (\k -> switching k [ "Sec-WebSocket-Protocol: chat" ]), identity )
    , ( "extension not offered", Answer (\k -> switching k [ "Sec-WebSocket-Extensions: permessage-deflate" ]), \o -> { o | compression = Nothing } )
    , ( "unknown extension", Answer (\k -> switching k [ "Sec-WebSocket-Extensions: x-foo" ]), identity )
    , ( "invalid deflate answer", Answer (\k -> switching k [ "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits" ]), identity )
    , ( "deflate accepted", Answer (\k -> switching k [ "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover" ]), identity )
    , ( "redirect", Answer (\_ -> crlf [ "HTTP/1.1 302 Found", "Location: /elsewhere", "Content-Length: 0" ]), identity )
    , ( "forbidden", Answer (\_ -> crlf [ "HTTP/1.1 403 Forbidden", "Content-Length: 4" ] ++ "nope"), identity )
    , ( "not http", Answer (\_ -> "hello there\u{000D}\n\u{000D}\n"), identity )
    , ( "closed", CloseAtOnce, identity )
    , ( "silent", Silent, \o -> { o | timeout = Just 300 } )
    , ( "chosen", Answer (\k -> switching k [ "Sec-WebSocket-Protocol: b" ]), \o -> { o | protocols = [ "a", "b" ] } )
    ]


runCase : Socket.Listener -> ( String, Server, WebSocket.ConnectOptions -> WebSocket.ConnectOptions ) -> Task String String
runCase listener ( label, server, change ) =
    H.async (serve listener server)
        |> Task.andThen
            (\serverDone ->
                W.connectWith change listener
                    |> Task.map (\ws -> ( "ok protocol " ++ Maybe.withDefault "-" (WebSocket.protocol ws) ++ compressionString ws, Just ws ))
                    |> Task.onError (\e -> Task.succeed ( e, Nothing ))
                    |> Task.andThen
                        (\( line, ws ) ->
                            (case ws of
                                Just w ->
                                    WebSocket.close WebSocket.Normal "" w |> Task.andThen (\_ -> WebSocket.closed w) |> Task.map (\_ -> ())

                                Nothing ->
                                    Task.succeed ()
                            )
                                |> Task.mapError W.wsErr
                                |> Task.andThen (\_ -> serverDone)
                                |> Task.map (\_ -> label ++ ": " ++ line)
                        )
            )


serve : Socket.Listener -> Server -> Task String ()
serve listener server =
    case server of
        Answer response ->
            W.rawUpgradeClient listener (\key -> H.bytesOf (response key))
                |> Task.andThen (\( conn, _ ) -> W.rawUntilClose conn |> Task.map (\_ -> ()))

        CloseAtOnce ->
            H.socketErr (Socket.accept listener)
                |> Task.andThen (\conn -> W.rawRead conn |> Task.andThen (\_ -> H.socketErr (Socket.close conn)))

        Silent ->
            H.socketErr (Socket.accept listener)
                |> Task.andThen (\conn -> W.rawReadAll conn |> Task.andThen (\_ -> H.socketErr (Socket.close conn)))


compressionString : WebSocket.WebSocket mode -> String
compressionString ws =
    case WebSocket.compression ws of
        Just n ->
            " compression "
                ++ H.boolString n.serverNoContextTakeover
                ++ " "
                ++ H.boolString n.clientNoContextTakeover
                ++ " "
                ++ String.fromInt n.serverMaxWindowBits
                ++ " "
                ++ String.fromInt n.clientMaxWindowBits

        Nothing ->
            ""


{-| What the server saw in the opening request.
-}
requestCase : Socket.Listener -> (WebSocket.ConnectOptions -> WebSocket.ConnectOptions) -> Task String String
requestCase listener change =
    H.async (W.rawUpgradeClient listener (\_ -> H.bytesOf (crlf [ "HTTP/1.1 400 Bad Request", "Content-Length: 0" ])))
        |> Task.andThen
            (\serverDone ->
                WebSocket.connect
                    (WebSocket.defaultConnectOptions (W.url listener "/test?x=1")
                        |> (\o -> { o | headers = [ ( "Origin", "http://example.com" ) ] })
                        |> change
                    )
                    |> Task.map (\_ -> ())
                    |> Task.onError (\_ -> Task.succeed ())
                    |> Task.andThen (\_ -> serverDone)
                    |> Task.map
                        (\( conn, head ) ->
                            let
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
                                        |> Maybe.withDefault "none"
                            in
                            String.join " | "
                                [ "request: " ++ (List.head lines |> Maybe.withDefault "")
                                , "host "
                                    ++ (if header "host" == "127.0.0.1:" ++ String.fromInt (H.portOf listener) then
                                            "ok"

                                        else
                                            header "host"
                                       )
                                , "upgrade " ++ header "upgrade"
                                , "connection " ++ header "connection"
                                , "version " ++ header "sec-websocket-version"
                                , "key " ++ String.fromInt (String.length (header "sec-websocket-key"))
                                , "origin " ++ header "origin"
                                , "extensions " ++ header "sec-websocket-extensions"
                                ]
                        )
            )


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                requestCase listener identity
                    |> Task.andThen
                        (\first ->
                            requestCase listener (\o -> { o | compression = Nothing })
                                |> Task.andThen
                                    (\second ->
                                        cases
                                            |> List.map (runCase listener)
                                            |> sequence
                                            |> Task.map (\rest -> first :: ("request without compression: " ++ lastPart second) :: rest)
                                    )
                        )
                    |> Task.andThen (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )


sequence : List (Task String String) -> Task String (List String)
sequence tasks =
    case tasks of
        [] ->
            Task.succeed []

        t :: rest ->
            t |> Task.andThen (\x -> sequence rest |> Task.map ((::) x))


lastPart : String -> String
lastPart line =
    String.split " | " line |> List.reverse |> List.head |> Maybe.withDefault ""
