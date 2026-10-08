module WebSocketHttp2ManyTest exposing (main)

{-| Many WebSockets over one HTTP/2 connection (RFC 8441; plans/eco-system-websockets.md §3.9, W19,
§4 WS9): a Node `http2` client opens 50 WebSockets (extended CONNECT streams, `/many/<i>`) and 10
ordinary GETs at once on one session to a server with the default options (no
`maxConcurrentStreams`: no cap). Every WebSocket's message is echoed and every WebSocket closes
cleanly (Close handshake, END_STREAM both ways); every GET is answered meanwhile.
-}

-- CHECK: client: enableConnectProtocol true
-- CHECK: client: websockets 50, echoed 50, closed cleanly 50
-- CHECK: client: requests 10, answered 10
-- CHECK: server: many: 50 done, 50 clean
-- CHECK-NOT: failed
-- CHECK-NOT: still running
-- CHECK-NOT: timeout
-- EXIT: 0

import Http.Server as Server
import Task exposing (Task)
import WebSocketH2Help as H


client : H.Tools -> List Server.Server -> Task String (List String)
client tools servers =
    case servers of
        server :: _ ->
            H.node tools (Server.serverPort server) "many" [ "50", "10" ]

        [] ->
            Task.fail "no server"


main =
    H.program { servers = [ identity ], client = client }
