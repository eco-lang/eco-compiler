module HttpServerTlsTest exposing (main)

{-| HTTPS (plans/eco-system-websockets.md §3.5, §4 WS3): `createServerWith` with `tls`, reached
by raw HTTP/1.1 over `Socket.Tls` clients trusting the test CA. Request URLs start with
`https://`; the server chooses ALPN itself (`http/1.1`), ignoring the `alpn` of its
`Socket.Tls.ServerOptions` (here `[ "h2" ]`); a client offering `h2` first still gets `http/1.1`
(the server has no `http2`); a client offering only `http/1.0`, or nothing, connects without
ALPN (alpnFallback = NoAck) and is served HTTP/1.1; keep-alive works over TLS; `http2 = True`
with `tls` offers `h2` (HTTP/2 itself: the `HttpServerHttp2*` tests) and fails `EINVAL` without
it; an unusable key fails with an `ERR_SSL_` code. (`Socket.Tls.listen` keeps the fatal alert on no overlap:
`SocketTlsAlpnTest`.)
-}

-- CHECK: server: GET https://localhost/a Http1_1
-- CHECK: server: GET https://localhost/b Http1_1
-- CHECK: server: GET https://localhost/c Http1_1
-- CHECK: server: GET https://localhost/d Http1_1
-- CHECK: server: GET https://localhost/e Http1_0
-- CHECK: client: http/1.1: alpn http/1.1
-- CHECK: client: http/1.1: 200 keep-alive a
-- CHECK: client: http/1.1: 200 close b
-- CHECK: client: http/1.1: closed
-- CHECK: client: h2,http/1.1: alpn http/1.1
-- CHECK: client: h2,http/1.1: 200 keep-alive c
-- CHECK: client: http/1.0 only: alpn none
-- CHECK: client: http/1.0 only: 200 keep-alive d
-- CHECK: client: no alpn: alpn none
-- CHECK: client: no alpn: 200 close e
-- CHECK: client: no alpn: closed
-- CHECK: client: http2 without tls: EINVAL
-- CHECK: client: http2 with tls: alpn h2
-- CHECK: client: bad key: ERR_SSL_ True
-- EXIT: 0

import Http.Server as Server exposing (HttpVersion(..))
import Http.Server.Response as Response
import HttpServerRawHelp as H
import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import Socket.Tls
import SocketTlsHelp as T
import Task exposing (Task)


version : HttpVersion -> String
version v =
    case v of
        Http1_0 ->
            "Http1_0"

        Http1_1 ->
            "Http1_1"

        Http2 ->
            "Http2"


handler : List String -> Server.Request -> Response.Response -> ( List String, H.Answer )
handler _ request response =
    -- The Host header carries no port, so the URL has none: "GET https://localhost/a".
    ( [ Server.requestInfo request ++ " " ++ version request.version ]
    , H.Now (response |> Response.setBody (String.dropLeft 1 request.url.path))
    )


withTls : Server.ServerOptions -> Server.ServerOptions
withTls options =
    { options | tls = Just (T.server [ "h2" ]) }


tlsConnect : List String -> Int -> Task String Socket.Connection
tlsConnect alpn port_ =
    Socket.Tls.connect (T.trusted "localhost" alpn)
        (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) port_)
        |> Task.mapError Socket.errorToString


alpnOf : Socket.Connection -> Task String String
alpnOf conn =
    Socket.Tls.info conn
        |> Task.map (\info -> "alpn " ++ T.alpnString info.alpn)
        |> Task.mapError Socket.errorToString


get : String -> String
get path =
    "GET " ++ path ++ " HTTP/1.1\u{000D}\nHost: localhost\u{000D}\n\u{000D}\n"


{-| Connect offering `alpn`, report the negotiated protocol, run `exchanges`, then close the
connection (if it is still open). Lines are prefixed with `name`.
-}
session : String -> List String -> (Socket.Connection -> Task String (List String)) -> Int -> Task String (List String)
session name alpn exchanges port_ =
    tlsConnect alpn port_
        |> Task.andThen
            (\conn ->
                alpnOf conn
                    |> Task.andThen (\a -> exchanges conn |> Task.map (\more -> a :: more))
                    |> Task.andThen (\lines -> Socket.close conn |> Task.map (\_ -> lines))
            )
        |> Task.map (List.map (\l -> name ++ ": " ++ l))


then_ : Task String (List String) -> Task String (List String) -> Task String (List String)
then_ next before =
    before |> Task.andThen (\lines -> next |> Task.map (\more -> lines ++ more))


startError : Server.ServerOptions -> Task String String
startError options =
    Server.createServerWith options
        |> Task.andThen (\s -> Server.closeServer s |> Task.map (\_ -> "started"))
        |> Task.onError (\(Server.ServerError e) -> Task.succeed e.code)


client : Server.Server -> Task String (List String)
client server =
    let
        port_ =
            Server.serverPort server

        plain =
            Server.defaultServerOptions (Address.loopback IPv4) 0
    in
    session "http/1.1"
        [ "http/1.1" ]
        (\conn ->
            H.exchange (get "/a") 1 False conn
                |> then_ (H.exchange ("GET /b HTTP/1.1\u{000D}\nHost: localhost\u{000D}\nConnection: close\u{000D}\n\u{000D}\n") 1 True conn)
        )
        port_
        |> then_ (session "h2,http/1.1" [ "h2", "http/1.1" ] (H.exchange (get "/c") 1 False) port_)
        |> then_ (session "http/1.0 only" [ "http/1.0" ] (H.exchange (get "/d") 1 False) port_)
        |> then_ (session "no alpn" [] (H.exchange "GET /e HTTP/1.0\u{000D}\nHost: localhost\u{000D}\n\u{000D}\n" 1 True) port_)
        |> then_
            (startError { plain | http2 = True }
                |> Task.map (\code -> [ "http2 without tls: " ++ code ])
            )
        |> then_
            (Server.createServerWith (withTls { plain | http2 = True })
                |> Task.mapError (\(Server.ServerError e) -> e.code)
                |> Task.andThen
                    (\s2 ->
                        session "http2 with tls" [ "h2", "http/1.1" ] (\_ -> Task.succeed []) (Server.serverPort s2)
                            |> Task.andThen (\lines -> Server.closeServer s2 |> Task.map (\_ -> lines))
                    )
            )
        |> then_
            (startError { plain | tls = Just { certificateChain = (T.server []).certificateChain, privateKey = "not a key", alpn = [] } }
                |> Task.map (\code -> [ "bad key: ERR_SSL_ " ++ (if String.startsWith "ERR_SSL_" code then "True" else "False " ++ code) ])
            )


main =
    H.program { options = withTls, handler = handler, client = client, exitAtEnd = True }
