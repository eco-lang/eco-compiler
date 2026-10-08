module WebSocketUrlTest exposing (main)

{-| WebSocket URLs (plans/eco-system-websockets.md §4 WS4, §3.6 "Handshake"): an IPv6 literal is
dialled and sent bracketed in `Host`; a URL without a path asks for `/`, a query is kept, the
scheme is case-insensitive and a non-default port is written in `Host`; invalid URLs fail
`EINVAL` before any IO, and a name that does not resolve fails `ENOTFOUND`.
-}

-- CHECK: ipv6: target /v6?a=b host [::1]:PORT
-- CHECK: no path: target / host 127.0.0.1:PORT
-- CHECK: query only: target /?q=1 host 127.0.0.1:PORT
-- CHECK: invalid ftp: EINVAL invalid WebSocket URL ftp://127.0.0.1/: the scheme must be ws or wss
-- CHECK: invalid fragment: EINVAL invalid WebSocket URL ws://127.0.0.1/a#b: fragments are not allowed
-- CHECK: invalid userinfo: EINVAL invalid WebSocket URL ws://user:pw@127.0.0.1/: user information is not allowed
-- CHECK: invalid port: EINVAL invalid WebSocket URL ws://127.0.0.1:99999/: invalid port
-- CHECK: invalid empty host: EINVAL invalid WebSocket URL ws:///x: missing host
-- CHECK: invalid ipv6: EINVAL invalid WebSocket URL ws://[::g]/: invalid IPv6 address
-- CHECK: invalid bracketed ipv4: EINVAL invalid WebSocket URL ws://[127.0.0.1]/: only IPv6 addresses are bracketed
-- CHECK: invalid unbracketed ipv6: EINVAL invalid WebSocket URL ws://::1/: IPv6 addresses must be bracketed
-- CHECK: invalid space: EINVAL invalid WebSocket URL ws://127.0.0.1/a b: invalid character
-- CHECK: unknown name: ENOTFOUND
-- EXIT: 0

import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import SocketTestHelp as H
import System
import Task exposing (Task)
import WebSocket
import WebSocketTestHelp as W


main : System.SimpleProgram ()
main =
    H.program run


{-| Dial `url`; the server reports the target and the Host header (the port as `PORT`).
-}
seen : String -> Socket.Listener -> (String -> String) -> Task String String
seen label listener makeUrl =
    H.async
        (W.upgrade listener
            |> Task.andThen
                (\up ->
                    let
                        host =
                            WebSocket.upgradeHeaders up
                                |> List.filter (\( n, _ ) -> n == "host")
                                |> List.map Tuple.second
                                |> String.join ","
                    in
                    WebSocket.reject 400 [] "" up
                        |> Task.map (\_ -> "target " ++ WebSocket.upgradeTarget up ++ " host " ++ String.replace (String.fromInt (H.portOf listener)) "PORT" host)
                )
        )
        |> Task.andThen
            (\serverDone ->
                WebSocket.connect (WebSocket.defaultConnectOptions (makeUrl (String.fromInt (H.portOf listener))))
                    |> Task.map (\_ -> ())
                    |> Task.onError (\_ -> Task.succeed ())
                    |> Task.andThen (\_ -> serverDone)
                    |> Task.map (\line -> label ++ ": " ++ line)
            )


invalid : ( String, String ) -> Task String String
invalid ( label, url ) =
    WebSocket.connect (WebSocket.defaultConnectOptions url)
        |> Task.map (\_ -> "invalid " ++ label ++ ": connected?")
        |> Task.onError (\e -> Task.succeed ("invalid " ++ label ++ ": " ++ Socket.errorCode e ++ " " ++ (Socket.errorToString e |> String.dropLeft (String.length (Socket.errorCode e) + 2))))


invalids : List ( String, String )
invalids =
    [ ( "ftp", "ftp://127.0.0.1/" )
    , ( "fragment", "ws://127.0.0.1/a#b" )
    , ( "userinfo", "ws://user:pw@127.0.0.1/" )
    , ( "port", "ws://127.0.0.1:99999/" )
    , ( "empty host", "ws:///x" )
    , ( "ipv6", "ws://[::g]/" )
    , ( "bracketed ipv4", "ws://[127.0.0.1]/" )
    , ( "unbracketed ipv6", "ws://::1/" )
    , ( "space", "ws://127.0.0.1/a b" )
    ]


run : a -> Task String (List String)
run _ =
    Socket.Tcp.listen (Socket.Tcp.defaultListenOptions (Address.loopback IPv6) 0)
        |> H.socketErr
        |> Task.andThen
            (\v6 ->
                seen "ipv6" v6 (\p -> "ws://[::1]:" ++ p ++ "/v6?a=b")
                    |> Task.andThen (\line -> H.socketErr (Socket.closeListener v6) |> Task.map (\_ -> line))
            )
        |> Task.andThen
            (\first ->
                H.socketErr H.listenLocal
                    |> Task.andThen
                        (\v4 ->
                            seen "no path" v4 (\p -> "WS://127.0.0.1:" ++ p)
                                |> Task.andThen (\a -> seen "query only" v4 (\p -> "ws://127.0.0.1:" ++ p ++ "?q=1") |> Task.map (\b -> [ first, a, b ]))
                                |> Task.andThen (\lines -> H.socketErr (Socket.closeListener v4) |> Task.map (\_ -> lines))
                        )
            )
        |> Task.andThen (\lines -> Task.sequence (List.map invalid invalids) |> Task.map (\more -> lines ++ more))
        |> Task.andThen
            (\lines ->
                WebSocket.connect (WebSocket.defaultConnectOptions "ws://no-such-host.invalid/")
                    |> Task.map (\_ -> "unknown name: connected?")
                    |> Task.onError (\e -> Task.succeed ("unknown name: " ++ Socket.errorCode e))
                    |> Task.map (\l -> lines ++ [ l ])
            )
