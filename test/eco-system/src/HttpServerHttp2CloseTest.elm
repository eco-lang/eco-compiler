module HttpServerHttp2CloseTest exposing (main)

{-| `closeServer` with HTTP/2 (plans/eco-system-websockets.md §3.4 "closeServer", §3.8, §4 WS8): a
Node `http2` client sends `/slow`; the server closes itself at once and answers 300 ms later. The
client gets GOAWAY (NO_ERROR) first; a stream it opens afterwards is not served; the request in
flight is still answered, and the connection then ends. The port is free afterwards.
-}

-- CHECK: server: GET /slow Http2
-- CHECK: server: closed
-- CHECK: client: goaway NO_ERROR
-- CHECK: client: after goaway: not served
-- CHECK: client: slow: 200 slow
-- CHECK: client: session closed
-- CHECK: client: port after close: ECONNREFUSED
-- CHECK-NOT: server: GET /late
-- EXIT: 0

import Http.Server as Server exposing (HttpVersion(..))
import Http.Server.Response as Response
import HttpServerH2Help as H
import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import Task exposing (Task)


handler : Server.Request -> Response.Response -> ( List String, H.Answer )
handler request response =
    let
        v =
            if request.version == Http2 then
                "Http2"

            else
                "other"
    in
    ( [ Server.methodToString request.method ++ " " ++ request.url.path ++ " " ++ v ]
    , if request.url.path == "/slow" then
        H.CloseThen 300 (response |> Response.setBody "slow")

      else
        H.Now (response |> Response.setBody "late")
    )


connectCode : Int -> Task x String
connectCode port_ =
    Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) port_)
        |> Task.andThen (\conn -> Socket.close conn |> Task.map (\_ -> "connected"))
        |> Task.onError (\e -> Task.succeed (Socket.errorCode e))


client : H.Tools -> List Server.Server -> Task String (List String)
client tools servers =
    case servers of
        server :: _ ->
            H.node tools server "close" []
                |> Task.andThen
                    (\lines ->
                        connectCode (Server.serverPort server)
                            |> Task.map (\code -> lines ++ [ "port after close: " ++ code ])
                    )

        [] ->
            Task.fail "no server"


main =
    H.program { servers = [ identity ], handler = handler, client = client }
