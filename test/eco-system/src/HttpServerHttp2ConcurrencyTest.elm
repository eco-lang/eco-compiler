module HttpServerHttp2ConcurrencyTest exposing (main)

{-| HTTP/2 concurrency (plans/eco-system-websockets.md §3.8, §4 WS8): a Node `http2` client sends
100 requests at once on one session; the server holds every answer until all 100 have arrived
(so they are all in progress together, with no `maxConcurrentStreams`), then answers them the
latest first (3 ms apart); each response reaches its own stream, and they end in about that
(reverse) order: the first to end is among the last ten requests, the last among the first ten.
-}

-- CHECK: server: 100 held, answering the latest first
-- CHECK: client: responses 100, bodies ok 100
-- CHECK: client: first to end is one of the last requests true
-- CHECK: client: last to end is one of the first requests true
-- EXIT: 0

import Http.Server as Server
import Http.Server.Response as Response
import HttpServerH2Help as H
import Task exposing (Task)


handler : Server.Request -> Response.Response -> ( List String, H.Answer )
handler request response =
    ( [], H.HoldReverse 100 (response |> Response.setBody ("c" ++ String.dropLeft 3 request.url.path)) )


client : H.Tools -> List Server.Server -> Task String (List String)
client tools servers =
    case servers of
        server :: _ ->
            H.node tools server "concurrency" [ "100" ]

        [] ->
            Task.fail "no server"


main =
    H.program { servers = [ identity ], handler = handler, client = client }
